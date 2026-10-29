// gen <table> <prefs.txt> <N> <max_plies>: prints one line of SAN per leaf.
// prefs.txt: one line per PGN line, UCI moves separated by spaces.
use orbt_core::chess::ChessPosition;
use orbt_core::explorer::table::CoverageTable;
use std::collections::{HashMap, HashSet};

struct G { root_only: bool, t: CoverageTable, own: HashMap<String, String>, opp: HashMap<String, HashSet<String>>, n: f64, max: usize, out: Vec<String> }

fn games(t: &CoverageTable, pos: &ChessPosition) -> i64 {
    t.stats(&pos.epd()).map(|s| s.moves.iter().map(|m| m.white + m.draws + m.black).sum()).unwrap_or(0)
}

impl G {
    fn grow(&mut self, pos: ChessPosition, p: f64, own_turn: bool, line: &mut Vec<String>) {
        let key = pos.epd().as_str().to_string();
        let before = line.len();
        if line.len() < self.max {
            if own_turn {
                let pick = self.own.get(&key).cloned().filter(|u| pos.play_uci(u).is_some_and(|(_, n)| games(&self.t, &n) > 0)).or_else(|| {
                    pos.legal_moves().into_iter()
                        .filter_map(|m| { let (_, n) = pos.play_uci(&m.uci)?; let g = games(&self.t, &n); (g > 0).then_some((g, m.uci)) })
                        .max().map(|(_, u)| u)
                });
                if let Some(u) = pick {
                    let (m, next) = pos.play_uci(&u).unwrap();
                    line.push(m.san);
                    self.grow(next, p, false, line);
                    line.pop();
                    return;
                }
            } else {
                let mut kids: Vec<(String, f64)> = Vec::new();
                if !(self.root_only && line.is_empty()) { if let Some(s) = self.t.stats(&pos.epd()) {
                    let total: i64 = s.moves.iter().map(|m| m.white + m.draws + m.black).sum();
                    if total >= 25 {
                        for m in &s.moves {
                            let share = (m.white + m.draws + m.black) as f64 / total as f64;
                            if p * share >= 1.0 / self.n { kids.push((m.uci.clone(), p * share)); }
                        }
                    }
                } }
                for u in self.opp.get(&key).cloned().unwrap_or_default() {
                    if !kids.iter().any(|(k, _)| *k == u) { kids.push((u, if self.root_only && line.is_empty() { 1.0 } else { p * 0.01 })); }
                }
                if !kids.is_empty() {
                    for (u, cp) in kids {
                        if let Some((m, next)) = pos.play_uci(&u) {
                            line.push(m.san);
                            self.grow(next, cp, true, line);
                            line.pop();
                        }
                    }
                    return;
                }
            }
        }
        if line.len() > before || !line.is_empty() { self.out.push(line.join(" ")); }
    }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let t = CoverageTable::from_bytes(std::fs::read(&a[1]).unwrap()).unwrap();
    let white = a[5] == "white";
    let mut own = HashMap::new();
    let mut opp: HashMap<String, HashSet<String>> = HashMap::new();
    for l in std::fs::read_to_string(&a[2]).unwrap().lines() {
        let mut pos = ChessPosition::start();
        for u in l.split_whitespace() {
            let is_own = (pos.side_to_move() == orbt_core::chess::Side::White) == white;
            let key = pos.epd().as_str().to_string();
            if is_own { own.insert(key, u.to_string()); } else { opp.entry(key).or_default().insert(u.to_string()); }
            pos = pos.play_uci(u).unwrap().1;
        }
    }
    let mut g = G { root_only: a.len() > 6 && a[6] == "rootonly", t, own, opp, n: a[3].parse().unwrap(), max: a[4].parse().unwrap(), out: vec![] };
    let mut line = vec![];
    g.grow(ChessPosition::start(), 1.0, white, &mut line);
    for l in g.out { println!("{l}"); }
}
