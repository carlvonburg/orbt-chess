//! Move-based shares from the PGN: classical OTB, both rated, average ≥ 2200; counts games whose
//! moves start with each given SAN prefix, and the next move played.
use pgn_reader::{RawTag, Reader, SanPlus, Visitor};
use std::collections::BTreeMap;
use std::ops::ControlFlow;

const FAST: [&str; 8] = ["blitz", "rapid", "bullet", "armageddon", "schnell", "rapide", "lampo", "speed"];
fn base_secs(tc: &str) -> Option<u32> {
    let first = tc.split(':').next()?.rsplit('/').next()?;
    let base: u32 = first.split('+').next()?.trim().parse().ok()?;
    Some(if base <= 120 { base * 60 } else { base })
}
#[derive(Default)] struct T { we: Option<u32>, be: Option<u32>, skip: bool }
struct V { out: Vec<Vec<String>> }
impl Visitor for V {
    type Tags = T; type Movetext = Option<Vec<String>>; type Output = ();
    fn begin_tags(&mut self) -> ControlFlow<(), T> { ControlFlow::Continue(T::default()) }
    fn tag(&mut self, t: &mut T, name: &[u8], v: RawTag<'_>) -> ControlFlow<()> {
        let v = v.decode_utf8_lossy();
        match name {
            b"WhiteElo" => t.we = v.trim().parse().ok().filter(|&x| x > 0),
            b"BlackElo" => t.be = v.trim().parse().ok().filter(|&x| x > 0),
            b"Mode" => t.skip |= v == "Correspondence",
            b"Event" => { let e = v.to_lowercase(); t.skip |= FAST.iter().any(|k| e.contains(k)); }
            b"TimeControl" => t.skip |= base_secs(&v).is_some_and(|b| b < 3600),
            _ => {}
        }
        ControlFlow::Continue(())
    }
    fn begin_movetext(&mut self, t: T) -> ControlFlow<(), Option<Vec<String>>> {
        let ok = !t.skip && matches!((t.we, t.be), (Some(w), Some(b)) if (w + b) / 2 >= 2200);
        ControlFlow::Continue(ok.then(Vec::new))
    }
    fn san(&mut self, m: &mut Option<Vec<String>>, s: SanPlus) -> ControlFlow<()> {
        if let Some(m) = m { if m.len() < 10 { m.push(s.san.to_string()); } }
        ControlFlow::Continue(())
    }
    fn begin_variation(&mut self, _: &mut Option<Vec<String>>) -> ControlFlow<(), pgn_reader::Skip> { ControlFlow::Continue(pgn_reader::Skip(true)) }
    fn end_game(&mut self, m: Option<Vec<String>>) { if let Some(m) = m { self.out.push(m); } }
}
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let f = std::fs::File::open(&args[0]).unwrap();
    let mut r = Reader::new(std::io::BufReader::with_capacity(1 << 22, f));
    let mut v = V { out: Vec::new() };
    while r.read_game(&mut v).unwrap().is_some() {}
    for p in &args[1..] {
        let pre: Vec<&str> = p.split_whitespace().collect();
        let mut next: BTreeMap<String, u64> = BTreeMap::new();
        let mut n = 0;
        for g in &v.out { if g.len() > pre.len() && g.iter().zip(&pre).all(|(a, b)| a == b) { n += 1; *next.entry(g[pre.len()].clone()).or_default() += 1; } }
        let mut top: Vec<_> = next.into_iter().collect();
        top.sort_by_key(|x| std::cmp::Reverse(x.1));
        println!("{p}: {n} games: {}", top.iter().take(5).map(|(m, c)| format!("{m} {:.1}%", 100.0 * *c as f64 / n as f64)).collect::<Vec<_>>().join(", "));
    }
}
