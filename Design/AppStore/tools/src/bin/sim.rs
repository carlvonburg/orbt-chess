// sim <table> <pgn> <sidecar.json> <out_dir> <today_day> <today_midnight_unix> <first_day_offset> <keep_root_uci|-> <seed>
// Studies the repertoire once a day (most days) from first_day_offset days ago up to yesterday,
// through the core's Drill, like a user would; writes <name>.otrep.json and <name>.otlog.jsonl.
use std::borrow::Cow;

use orbt_core::chess::{BoardSquare, Epd, PieceKind};
use orbt_core::coverage::StatsSource;
use orbt_core::document::{Repertoire, StudyDefaults};
use orbt_core::drill::{Drill, DrillMode, Feedback, Phase};
use orbt_core::explorer::ExplorerStats;
use orbt_core::explorer::table::CoverageTable;
use orbt_core::formats::Timestamp;
use orbt_core::repertoire::RepertoireTree;
use orbt_core::training::anki::SchedTiming;

struct Table(CoverageTable);
impl StatsSource for Table {
    fn stats(&self, epd: &Epd) -> Option<Cow<'_, ExplorerStats>> {
        self.0.stats(epd).map(Cow::Owned)
    }
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> f64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 % 1_000_000) as f64 / 1_000_000.0
    }
}

fn timing(day: i64, midnight: i64, now: i64) -> SchedTiming {
    let next = if now >= midnight + 4 * 3600 { midnight + 86_400 + 4 * 3600 } else { midnight + 4 * 3600 };
    let d = if now >= midnight + 4 * 3600 { day } else { day - 1 };
    SchedTiming::new(d, next, now)
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let stats = Table(CoverageTable::from_bytes(std::fs::read(&a[1]).unwrap()).unwrap());
    let pgn = std::fs::read_to_string(&a[2]).unwrap();
    let sidecar = std::fs::read(&a[3]).unwrap();
    let out = std::path::Path::new(&a[4]);
    let today: i64 = a[5].parse().unwrap();
    let today_midnight: i64 = a[6].parse().unwrap();
    let first: i64 = a[7].parse().unwrap();
    let keep = a[8].clone();
    let mut rng = Rng(a[9].parse().unwrap());
    let name = std::path::Path::new(&a[2]).file_stem().unwrap().to_string_lossy().to_string();

    let (mut doc, _) = Repertoire::open(&pgn, &sidecar, StudyDefaults::default(), &stats).unwrap();
    let start_secs = today_midnight - first * 86_400 + 9 * 3600;
    if keep != "-" {
        if let Some(s) = stats.0.stats(&doc.tree().get(RepertoireTree::ROOT).unwrap().epd) {
            let total: i64 = s.moves.iter().map(|m| m.white + m.draws + m.black).sum();
            for m in &s.moves {
                let n = m.white + m.draws + m.black;
                if m.uci != keep && n * 1000 >= total {
                    doc.set_excluded(&m.uci, RepertoireTree::ROOT, true, Timestamp::from_secs(start_secs), &stats);
                }
            }
        }
    }

    for (epd, r) in doc.coverage().pending_positions(doc.tree()) {
        eprintln!("pending {} {:.4}", epd.as_str(), r);
    }
    if std::env::var("PENDING_ONLY").is_ok() { return; }
    let mut revlog: Vec<u8> = Vec::new();
    let mut sessions = 0;
    for k in (1..=first).rev() {
        // Skip about one day in six, never the first.
        if k != first && rng.next() < 0.17 {
            continue;
        }
        let midnight = today_midnight - k * 86_400;
        let mut now = midnight + 18 * 3600 + (rng.next() * 3.5 * 3600.0) as i64;
        let mut ms = now * 1000;
        let mut drill = Drill::new(DrillMode::Study);
        drill.start(&mut doc, 0, &timing(today - k, midnight, now));
        sessions += 1;
        let mut wrong_pending = false;
        for _ in 0..200_000 {
            now = ms / 1000;
            let t = timing(today - k, midnight, now);
            match drill.phase {
                Phase::Rewinding | Phase::Autoplay => {
                    ms += 350;
                    drill.step(ms);
                }
                Phase::UserTurn => {
                    let expected = drill.run().and_then(|r| r.expected()).cloned().unwrap();
                    if matches!(drill.feedback, Feedback::Wrong { .. }) {
                        ms += 1200;
                        drill.wrong_timeout();
                        wrong_pending = true;
                        continue;
                    }
                    let is_new = matches!(drill.feedback, Feedback::NewMove(_));
                    ms += if is_new { 2500 } else { 1200 } + (rng.next() * 5000.0) as i64;
                    let p_wrong = if is_new || wrong_pending { 0.0 } else { 0.09 };
                    wrong_pending = false;
                    let pos = drill.position(&doc);
                    let mv = if rng.next() < p_wrong {
                        let others: Vec<_> = pos.legal_moves().into_iter().filter(|m| m.uci != expected.uci).collect();
                        if others.is_empty() { expected.clone() } else { others[(rng.next() * others.len() as f64) as usize % others.len()].clone() }
                    } else {
                        expected.clone()
                    };
                    let promo = mv.uci.chars().nth(4).and_then(PieceKind::from_char);
                    let (from, to) = (BoardSquare::parse(&mv.uci[0..2]).unwrap(), BoardSquare::parse(&mv.uci[2..4]).unwrap());
                    drill.user_moved(&mut doc, from, to, promo, &t, ms);
                    if drill.feedback == Feedback::Alternative {
                        let (f, to) = (BoardSquare::parse(&expected.uci[0..2]).unwrap(), BoardSquare::parse(&expected.uci[2..4]).unwrap());
                        drill.user_moved(&mut doc, f, to, None, &t, ms);
                    }
                }
                Phase::LineDone => {
                    ms += 800;
                    drill.next_line(&doc, &timing(today - k, midnight, ms / 1000));
                }
                Phase::Finished => match drill.next_learning_due() {
                    Some(due) if due - now <= 20 * 60 => {
                        ms = (due.max(now) + 5) * 1000;
                        drill.check_again(&doc, &timing(today - k, midnight, ms / 1000));
                        if drill.phase == Phase::Finished {
                            break;
                        }
                    }
                    _ => break,
                },
                Phase::Idle => break,
            }
        }
        if let Some(bytes) = doc.revlog_to_append() {
            revlog.extend(bytes);
            doc.revlog_appended();
        }
    }
    // Saved as the app would this morning.
    let morning = today_midnight + 9 * 3600;
    let t = timing(today, today_midnight, morning);
    let pgn_out = doc.pgn_to_save().unwrap_or(pgn);
    std::fs::write(out.join(format!("{name}.pgn")), pgn_out).unwrap();
    std::fs::write(out.join(format!("{name}.otrep.json")), doc.sidecar_to_save(&t).unwrap()).unwrap();
    std::fs::write(out.join(format!("{name}.otlog.jsonl")), revlog).unwrap();
    let counts = doc.study_counts(&t);
    eprintln!("{name}: {sessions} sessions, due today {counts:?}");
}
