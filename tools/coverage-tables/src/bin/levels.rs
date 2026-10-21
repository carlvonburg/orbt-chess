// Games per average-Elo bin, split into correspondence / fast OTB (blitz, rapid) / classical OTB.
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader};

const BINS: [u32; 12] = [0, 600, 800, 1000, 1200, 1400, 1600, 1800, 2000, 2200, 2500, 9999];
fn bin(x: u32) -> usize { BINS.windows(2).position(|w| x < w[1]).unwrap() }

#[derive(Default)]
struct G { we: Option<u32>, be: Option<u32>, corr: bool, fast: bool }

/// Base time in seconds of a PGN TimeControl, when it can be read ("180+2", "40/5400+30:...", "3+2" in minutes).
fn base_secs(tc: &str) -> Option<u32> {
    let first = tc.split(':').next()?;
    let first = first.rsplit('/').next()?;
    let base: u32 = first.split('+').next()?.trim().parse().ok()?;
    Some(if base <= 120 { base * 60 } else { base })
}

fn main() {
    let path = std::env::args().nth(1).unwrap();
    let r = BufReader::with_capacity(1 << 22, std::fs::File::open(path).unwrap());
    let mut t: BTreeMap<&str, [u64; 12]> = BTreeMap::new();
    let mut g = G::default(); let mut in_header = false;
    let mut finish = |g: &G| {
        let class = if g.corr { "correspondence" } else if g.fast { "fast OTB" } else { "classical OTB" };
        let row = t.entry(class).or_default();
        match (g.we, g.be) { (Some(w), Some(b)) => row[bin((w + b) / 2)] += 1, _ => row[11] += 1 }
    };
    for line in r.split(b'\n') {
        let line = line.unwrap();
        if line.first() == Some(&b'[') {
            if !in_header { in_header = true; g = G::default(); }
            let s = String::from_utf8_lossy(&line);
            let Some((name, rest)) = s[1..].split_once(' ') else { continue };
            let val = rest.trim_end_matches(|c| c == ']' || c == '\r').trim_matches('"');
            match name {
                "WhiteElo" => g.we = val.parse().ok().filter(|&x| x > 0),
                "BlackElo" => g.be = val.parse().ok().filter(|&x| x > 0),
                "Mode" => g.corr |= val == "Correspondence",
                "Event" => { let e = val.to_lowercase(); g.fast |= ["blitz", "rapid", "bullet", "armageddon", "schnell", "rapide", "lampo", "speed"].iter().any(|k| e.contains(k)); }
                "TimeControl" => g.fast |= base_secs(val).is_some_and(|b| b < 3600),
                _ => {}
            }
        } else if in_header && !line.iter().all(|c| c.is_ascii_whitespace()) { in_header = false; finish(&g); }
    }
    if in_header { finish(&g); }
    let names = ["0-599", "600-799", "800-999", "1000-1199", "1200-1399", "1400-1599", "1600-1799", "1800-1999", "2000-2199", "2200-2499", "2500plus", "unrated"];
    print!("{:>15}", "avg Elo"); for c in t.keys() { print!("{c:>16}"); } println!();
    for (i, n) in names.iter().enumerate() { print!("{n:>15}"); for row in t.values() { print!("{:>16}", row[i]); } println!(); }
    print!("{:>15}", "total"); for row in t.values() { print!("{:>16}", row.iter().sum::<u64>()); } println!();
}
