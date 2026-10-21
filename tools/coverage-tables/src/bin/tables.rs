//! Builds OTCB coverage tables (one per Elo bin) from an OTB PGN.
//! Usage: build <pgn> <out dir> <lichess tables dir (for evals)>
//!
//! Games: standard start, classical OTB (no correspondence, no blitz/rapid by event name or time
//! control), both players rated, duplicates (same players, date and moves) dropped.
//! Bins by average Elo: 1400-1599 … 2200-2499, 2500plus (Masters, both players ≥ 2200, is counted for
//! the comparisons only).
//! Games from FROM_YEAR on. Counts: per move, the games that played it in the position (reached by
//! any move order), once per game, over the first MAX_PLY plies; positions keyed by Zobrist hash of
//! the 4-field FEN (ep only when legal). Walk: own moves with ≥ OWN_SHARE share, opponent moves while
//! p·share ≥ 1/N, stop below MIN_GAMES, both colours, union.
#[path = "../otcb.rs"]
#[allow(dead_code)]
mod otcb;

use std::collections::BTreeMap;
use std::hash::{Hash, Hasher};
use std::io::{Read, Seek, SeekFrom};
use std::ops::ControlFlow;
use std::time::Instant;

use pgn_reader::{RawTag, Reader, SanPlus, Visitor};
use rayon::prelude::*;
use rustc_hash::{FxHashMap, FxHashSet, FxHasher};
use shakmaty::{zobrist::Zobrist64, Chess, Color, EnPassantMode, Position};

const MAX_PLY: usize = 70;
/// Games from this year on (games without a year are dropped).
const FROM_YEAR: u32 = 2000;
const MIN_GAMES: u64 = 25;
const OWN_SHARE: f64 = 0.05;
/// Average-Elo bins: (lower bound, file label). Index 6 is Masters.
const BINS: [(u32, &str); 6] = [(1400, "1400-1599"), (1600, "1600-1799"), (1800, "1800-1999"), (2000, "2000-2199"), (2200, "2200-2499"), (2500, "2500plus")];
const NB: usize = 7;
const MASTERS: usize = 6;
const FAST: [&str; 8] = ["blitz", "rapid", "bullet", "armageddon", "schnell", "rapide", "lampo", "speed"];

type Counts = [[u32; 3]; NB];

fn zob(pos: &Chess) -> u64 { pos.zobrist_hash::<Zobrist64>(EnPassantMode::Legal).0 }

fn base_secs(tc: &str) -> Option<u32> {
    let first = tc.split(':').next()?.rsplit('/').next()?;
    let base: u32 = first.split('+').next()?.trim().parse().ok()?;
    Some(if base <= 120 { base * 60 } else { base })
}

#[derive(Default)]
struct Tags { year: Option<u32>, we: Option<u32>, be: Option<u32>, corr: bool, fast: bool, setup: bool, variant: bool, result: Option<u8>, ident: FxHasher }

#[derive(Default, Clone, Copy)]
struct Stats { games: u64, old: u64, setup: u64, corr: u64, fast: u64, unrated: u64, low: u64, no_result: u64, bad_moves: u64, kept: u64 }

struct Game { mask: u8, result: u8, ident: u64, end: usize }

struct Chunk { stats: Stats, keys: Vec<u64>, games: Vec<Game> }

struct Collector { chunk: Chunk }

struct Movetext { pos: Chess, ident: FxHasher, mask: u8, result: u8, ply: usize, start: usize, bad: bool }

impl Visitor for Collector {
    type Tags = Tags;
    type Movetext = Option<Movetext>;
    type Output = ();

    fn begin_tags(&mut self) -> ControlFlow<(), Tags> { ControlFlow::Continue(Tags::default()) }

    fn tag(&mut self, t: &mut Tags, name: &[u8], value: RawTag<'_>) -> ControlFlow<()> {
        let v = value.decode_utf8_lossy();
        match name {
            b"WhiteElo" => t.we = v.trim().parse().ok().filter(|&x| x > 0),
            b"BlackElo" => t.be = v.trim().parse().ok().filter(|&x| x > 0),
            b"Mode" => t.corr |= v == "Correspondence",
            b"Event" => { let e = v.to_lowercase(); t.fast |= FAST.iter().any(|k| e.contains(k)); }
            b"TimeControl" => t.fast |= base_secs(&v).is_some_and(|b| b < 3600),
            b"FEN" => t.setup = true,
            b"SetUp" => t.setup |= v == "1",
            b"Variant" => t.variant = !v.eq_ignore_ascii_case("standard"),
            b"Result" => t.result = match &*v { "1-0" => Some(0), "1/2-1/2" => Some(1), "0-1" => Some(2), _ => None },
            b"White" | b"Black" | b"Date" => {
                if name == b"Date" { t.year = v.get(0..4).and_then(|y| y.parse().ok()); }
                name.hash(&mut t.ident);
                v.hash(&mut t.ident);
            }
            _ => {}
        }
        ControlFlow::Continue(())
    }

    fn begin_movetext(&mut self, t: Tags) -> ControlFlow<(), Option<Movetext>> {
        let s = &mut self.chunk.stats;
        s.games += 1;
        let skip = if t.setup || t.variant { Some(&mut s.setup) } else if t.corr { Some(&mut s.corr) } else if t.fast { Some(&mut s.fast) } else if t.we.is_none() || t.be.is_none() { Some(&mut s.unrated) } else if t.year.is_none_or(|y| y < FROM_YEAR) { Some(&mut s.old) } else { None };
        if let Some(skip) = skip { *skip += 1; return ControlFlow::Continue(None); }
        let (w, b) = (t.we.unwrap(), t.be.unwrap());
        let avg = (w + b) / 2;
        let mut mask = BINS.iter().rposition(|&(lo, _)| avg >= lo).map_or(0u8, |i| 1 << i);
        if w.min(b) >= 2200 { mask |= 1 << MASTERS; }
        if mask == 0 { s.low += 1; return ControlFlow::Continue(None); }
        let Some(result) = t.result else { s.no_result += 1; return ControlFlow::Continue(None) };
        ControlFlow::Continue(Some(Movetext { pos: Chess::default(), ident: t.ident, mask, result, ply: 0, start: self.chunk.keys.len(), bad: false }))
    }

    fn san(&mut self, m: &mut Option<Movetext>, san: SanPlus) -> ControlFlow<()> {
        let Some(m) = m else { return ControlFlow::Continue(()) };
        san.san.hash(&mut m.ident);
        if m.ply < MAX_PLY && !m.bad {
            match san.san.to_move(&m.pos) {
                Ok(mv) => { m.pos.play_unchecked(mv); self.chunk.keys.push(zob(&m.pos)); m.ply += 1; }
                Err(_) => m.bad = true,
            }
        }
        ControlFlow::Continue(())
    }

    fn begin_variation(&mut self, _: &mut Option<Movetext>) -> ControlFlow<(), pgn_reader::Skip> { ControlFlow::Continue(pgn_reader::Skip(true)) }

    fn end_game(&mut self, m: Option<Movetext>) {
        let Some(m) = m else { return };
        if m.bad { self.chunk.keys.truncate(m.start); self.chunk.stats.bad_moves += 1; return; }
        self.chunk.stats.kept += 1;
        self.chunk.games.push(Game { mask: m.mask, result: m.result, ident: m.ident.finish(), end: self.chunk.keys.len() });
    }
}

/// Byte offsets splitting the file into `n` parts at game starts ("\n\n[" or file start).
fn split_points(path: &str, n: usize) -> Vec<u64> {
    let len = std::fs::metadata(path).unwrap().len();
    let mut f = std::fs::File::open(path).unwrap();
    let mut pts = vec![0];
    for i in 1..n {
        let mut off = len * i as u64 / n as u64;
        f.seek(SeekFrom::Start(off)).unwrap();
        let mut buf = vec![0u8; 1 << 20];
        let k = f.read(&mut buf).unwrap();
        let p = buf[..k].windows(3).position(|w| w == b"\n\n[").expect("no game start");
        off += p as u64 + 2;
        pts.push(off);
    }
    pts.push(len);
    pts
}

fn read_part(path: &str, from: u64, to: u64) -> Chunk {
    let mut f = std::fs::File::open(path).unwrap();
    f.seek(SeekFrom::Start(from)).unwrap();
    let mut c = Collector { chunk: Chunk { stats: Stats::default(), keys: Vec::new(), games: Vec::new() } };
    let mut reader = Reader::new(std::io::BufReader::with_capacity(1 << 22, f.take(to - from)));
    while reader.read_game(&mut c).unwrap().is_some() {}
    c.chunk
}

/// Move counts of one table: (parent, child) position keys -> counts per bin.
type Edges = FxHashMap<(u64, u64), Counts>;

struct Counter<'a> { edges: &'a Edges, bin: usize }

impl Counter<'_> {
    fn games(c: [u32; 3]) -> u64 { c.iter().map(|&x| x as u64).sum() }

    /// Moves with games: (index in sorted legal moves, child, counts).
    fn children(&self, pos: &Chess) -> Vec<(u8, Chess, [u32; 3])> {
        let key = zob(pos);
        otcb::sorted_moves(pos).into_iter().enumerate().filter_map(|(i, m)| {
            let mut c = pos.clone();
            c.play_unchecked(m);
            let k = self.edges.get(&(key, zob(&c))).map_or([0; 3], |e| e[self.bin]);
            (Self::games(k) > 0).then_some((i as u8, c, k))
        }).collect()
    }

    /// The walk; a position's games are the sum of its moves (as the app reads a table).
    /// Records opponent-to-move positions and required replies (with p·share).
    fn walk(&self, pos: &Chess, p: f64, user: Color, n: f64, best: &mut FxHashMap<u64, f64>, out: &mut FxHashSet<u64>, req: &mut FxHashMap<(u64, u64), f64>) {
        let key = zob(pos);
        if best.get(&key).is_some_and(|&b| b >= p) { return; }
        best.insert(key, p);
        let ch = self.children(pos);
        let sum: u64 = ch.iter().map(|c| Self::games(c.2)).sum();
        if sum < MIN_GAMES { return; }
        let own = pos.turn() == user;
        if !own { out.insert(key); }
        for (_, c, k) in ch {
            let share = Self::games(k) as f64 / sum as f64;
            if own { if share >= OWN_SHARE { self.walk(&c, p, user, n, best, out, req); } }
            else if p * share >= 1.0 / n {
                let r = req.entry((key, zob(&c))).or_insert(0.0);
                *r = r.max(p * share);
                self.walk(&c, p * share, user, n, best, out, req);
            }
        }
    }

    /// Opponent-to-move positions of the walk for both colours, and the required replies.
    fn run(&self, n: u32) -> (Vec<Chess>, FxHashMap<(u64, u64), f64>) {
        let (mut keys, mut req) = (FxHashSet::default(), FxHashMap::default());
        for user in [Color::White, Color::Black] {
            self.walk(&Chess::default(), 1.0, user, n as f64, &mut FxHashMap::default(), &mut keys, &mut req);
        }
        let mut found: FxHashMap<u64, Chess> = FxHashMap::default();
        let mut stack = vec![Chess::default()];
        let mut seen = FxHashSet::default();
        while let Some(pos) = stack.pop() {
            let k = zob(&pos);
            if !seen.insert(k) { continue; }
            if keys.contains(&k) { found.insert(k, pos.clone()); }
            if found.len() == keys.len() { break; }
            for (_, c, _) in self.children(&pos) { stack.push(c); }
        }
        assert_eq!(found.len(), keys.len());
        (found.into_values().collect(), req)
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (pgn, out_dir, lichess_dir) = (&args[1], &args[2], &args[3]);
    let t0 = Instant::now();

    // 1. Read and filter.
    let pts = split_points(pgn, 16);
    let chunks: Vec<Chunk> = pts.windows(2).collect::<Vec<_>>().into_par_iter().map(|w| read_part(pgn, w[0], w[1])).collect();
    let mut st = Stats::default();
    for c in &chunks { let s = c.stats; st.games += s.games; st.setup += s.setup; st.corr += s.corr; st.fast += s.fast; st.unrated += s.unrated; st.old += s.old; st.low += s.low; st.no_result += s.no_result; st.bad_moves += s.bad_moves; st.kept += s.kept; }
    eprintln!("[{:.0}s] read: {} games", t0.elapsed().as_secs_f64(), st.games);
    println!("games in PGN:                 {:>10}", st.games);
    println!("  dropped, FEN/variant:       {:>10}", st.setup);
    println!("  dropped, correspondence:    {:>10}", st.corr);
    println!("  dropped, blitz/rapid:       {:>10}", st.fast);
    println!("  dropped, a player unrated:  {:>10}", st.unrated);
    println!("  dropped, before {FROM_YEAR}/no date:{:>10}", st.old);
    println!("  dropped, average < 1400:    {:>10}", st.low);
    println!("  dropped, no result:         {:>10}", st.no_result);
    println!("  dropped, illegal move:      {:>10}", st.bad_moves);
    println!("kept before dedup:            {:>10}", st.kept);

    // 2. Dedup (first occurrence in file order wins), list games as key slices.
    let mut idents = FxHashSet::default();
    let mut games: Vec<(&[u64], u8, u8, u64)> = Vec::new();
    for c in &chunks {
        let mut start = 0;
        for g in &c.games {
            if idents.insert(g.ident) { games.push((&c.keys[start..g.end], g.mask, g.result, g.ident)); }
            start = g.end;
        }
    }
    drop(idents);
    println!("  dropped, duplicate:         {:>10}", st.kept - games.len() as u64);
    println!("kept:                         {:>10}", games.len());
    let mut per_bin = [0u64; NB];
    for g in &games { for b in 0..NB { if g.1 >> b & 1 == 1 { per_bin[b] += 1; } } }
    for (i, (_, l)) in BINS.iter().enumerate() { println!("  {l:>10}: {:>10}", per_bin[i]); }
    println!("  {:>10}: {:>10}", "masters", per_bin[MASTERS]);

    // 3. Totals per position (once per game), then per-bin counts of the moves from positions
    // with ≥ MIN_GAMES games in total: every move a walk may look at.
    let uniq = |keys: &[u64]| { let mut v = keys.to_vec(); v.sort_unstable(); v.dedup(); v };
    let mut all: Vec<u64> = games.par_iter().flat_map_iter(|g| uniq(g.0)).collect();
    all.par_sort_unstable();
    let mut frequent: FxHashSet<u64> = FxHashSet::default();
    let mut distinct = 0u64;
    for run in all.chunk_by(|a, b| a == b) { distinct += 1; if run.len() as u64 >= MIN_GAMES { frequent.insert(run[0]); } }
    drop(all);
    eprintln!("[{:.0}s] {distinct} distinct positions in the first {MAX_PLY} plies, {} with ≥ {MIN_GAMES} games", t0.elapsed().as_secs_f64(), frequent.len());
    let start_key = zob(&Chess::default());
    // Move counts (parent, child) for frequent parents.
    let mut exact: Edges = FxHashMap::default();
    let add = |c: &mut Counts, mask: u8, r: u8| { for b in 0..NB { if mask >> b & 1 == 1 { c[b][r as usize] += 1; } } };
    for g in &games {
        let mut es: Vec<(u64, u64)> = (0..g.0.len()).map(|i| (if i == 0 { start_key } else { g.0[i - 1] }, g.0[i]))
            .filter(|&(p, _)| p == start_key || frequent.contains(&p)).collect();
        es.sort_unstable();
        es.dedup();
        for e in es { add(exact.entry(e).or_insert([[0; 3]; NB]), g.1, g.2); }
    }
    eprintln!("[{:.0}s] counted {} moves", t0.elapsed().as_secs_f64(), exact.len());
    drop(games);
    drop(chunks);
    drop(frequent);

    // 4. Evals from the Lichess tables: position eval and per-move evals by FEN.
    let mut evals: FxHashMap<String, otcb::Entry> = FxHashMap::default();
    let tables: Vec<_> = (0..NB).map(|bin| (bin, Counter { edges: &exact, bin })).collect();
    let positions: Vec<(usize, u32, Vec<Chess>)> = tables[..MASTERS].par_iter().flat_map(|(bin, c)| [200u32, 800].into_par_iter().map(move |n| (*bin, n, c.run(n).0))).collect();
    let wanted: FxHashSet<String> = positions.iter().flat_map(|p| p.2.iter().map(otcb::fen_key)).collect();
    let mut lichess_files: Vec<_> = std::fs::read_dir(lichess_dir).unwrap().filter_map(|e| e.ok()).map(|e| e.path())
        .filter(|p| { let n = p.file_name().unwrap().to_string_lossy().to_string(); (n.starts_with("blitz_") || n.starts_with("rapid_")) && n.ends_with("_1in800.otcb.zst") }).collect();
    lichess_files.sort();
    for f in &lichess_files {
        let bytes = zstd::decode_all(std::fs::File::open(f).unwrap()).unwrap();
        let t = otcb::Table::parse(&bytes).unwrap();
        for fen in t.fens() {
            let fen = std::str::from_utf8(fen).unwrap();
            if !wanted.contains(fen) { continue; }
            let e = t.get(fen).unwrap();
            let slot = evals.entry(fen.to_string()).or_insert(otcb::Entry { eval: None, moves: Vec::new() });
            if slot.eval.is_none() { slot.eval = e.eval; }
            for m in e.moves { if m.eval.is_some() && !slot.moves.iter().any(|x| x.index == m.index) { slot.moves.push(m); } }
        }
    }
    eprintln!("[{:.0}s] evals for {} of {} positions from {} Lichess tables", t0.elapsed().as_secs_f64(), evals.len(), wanted.len(), lichess_files.len());

    // 5. Write.
    let mut sizes = BTreeMap::new();
    for (bin, n, ps) in &positions {
        let c = &tables[*bin].1;
        if *bin == MASTERS { continue; }
        let (file, name) = (format!("otb_{}", BINS[*bin].1), format!("otb_{0}-{0}", BINS[*bin].0));
        let records: Vec<Vec<u8>> = ps.iter().map(|pos| {
            let fen = otcb::fen_key(pos);
            let ev = evals.get(&fen);
            let moves = c.children(pos).into_iter().map(|(index, _, k)| otcb::MoveStats {
                index, white: k[0] as u64, draw: k[1] as u64, black: k[2] as u64,
                eval: ev.and_then(|e| e.moves.iter().find(|m| m.index == index)).and_then(|m| m.eval),
            }).collect();
            otcb::encode_record(&fen, &otcb::Entry { eval: ev.and_then(|e| e.eval), moves })
        }).collect();
        let path = format!("{out_dir}/{file}_1in{n}.otcb");
        let raw = otcb::write(&path, *n, &name, records).unwrap();
        sizes.insert(format!("{file}_1in{n}"), (name, ps.len(), raw));
    }
    println!("\ntables (name, positions, raw bytes):");
    for (f, (name, count, raw)) in &sizes { println!("  {f:<24} {name:<16} {count:>8} {raw:>12}"); }
    eprintln!("[{:.0}s] done", t0.elapsed().as_secs_f64());
}
