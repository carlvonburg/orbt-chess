// Classical OTB games with both players rated: per year, and per 5-year period × average-Elo bin.
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader};

const BINS: [u32; 7] = [1200, 1400, 1600, 1800, 2000, 2200, 2500];

#[derive(Default)]
struct G { we: Option<u32>, be: Option<u32>, year: Option<u32>, corr: bool, fast: bool }

fn base_secs(tc: &str) -> Option<u32> {
    let first = tc.split(':').next()?.rsplit('/').next()?;
    let base: u32 = first.split('+').next()?.trim().parse().ok()?;
    Some(if base <= 120 { base * 60 } else { base })
}

fn main() {
    let path = std::env::args().nth(1).unwrap();
    let r = BufReader::with_capacity(1 << 22, std::fs::File::open(path).unwrap());
    let mut years: BTreeMap<u32, u64> = BTreeMap::new();
    let mut grid: BTreeMap<u32, [u64; 8]> = BTreeMap::new();
    let mut g = G::default(); let mut in_header = false;
    let mut finish = |g: &G| {
        if g.corr || g.fast { return; }
        let (Some(w), Some(b)) = (g.we, g.be) else { return };
        let y = g.year.unwrap_or(0);
        *years.entry(y).or_default() += 1;
        let avg = (w + b) / 2;
        let col = BINS.iter().rposition(|&lo| avg >= lo).map_or(0, |i| i + 1);
        grid.entry(if y == 0 { 0 } else { y / 5 * 5 }).or_default()[col] += 1;
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
                "Date" => g.year = val.get(0..4).and_then(|y| y.parse().ok()),
                "Mode" => g.corr |= val == "Correspondence",
                "Event" => { let e = val.to_lowercase(); g.fast |= ["blitz", "rapid", "bullet", "armageddon", "schnell", "rapide", "lampo", "speed"].iter().any(|k| e.contains(k)); }
                "TimeControl" => g.fast |= base_secs(val).is_some_and(|b| b < 3600),
                _ => {}
            }
        } else if in_header && !line.iter().all(|c| c.is_ascii_whitespace()) { in_header = false; finish(&g); }
    }
    if in_header { finish(&g); }
    println!("per year:"); for (y, n) in &years { println!("{y:>6} {n:>9}"); }
    println!("\n{:>9}{:>9}{:>11}{:>11}{:>11}{:>11}{:>11}{:>11}{:>11}", "period", "<1200", "1200-1399", "1400-1599", "1600-1799", "1800-1999", "2000-2199", "2200-2499", "2500plus");
    for (p, row) in &grid { print!("{:>9}", if *p == 0 { "no date".to_string() } else { format!("{p}-{}", (p + 4) % 100) }); for x in row { print!("{x:>9}  "); } println!(); }
}
