// Header-only scan of a PGN: rating levels, tags, years, sources.
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader};

#[derive(Default)]
struct G { we: Option<u32>, be: Option<u32>, year: Option<u32>, fen: bool, variant: bool, source: String, quality: String }

const BINS: [u32; 12] = [0, 600, 800, 1000, 1200, 1400, 1600, 1800, 2000, 2200, 2500, 9999];
fn bin(x: u32) -> String {
    for w in BINS.windows(2) { if x < w[1] { return if w[0] == 2500 { "2500plus".into() } else { format!("{}-{}", w[0], w[1] - 1) }; } }
    "?".into()
}

fn main() {
    let path = std::env::args().nth(1).unwrap();
    let r = BufReader::with_capacity(1 << 22, std::fs::File::open(path).unwrap());
    let mut total = 0u64;
    let mut tags: BTreeMap<String, u64> = BTreeMap::new();
    let mut rated: BTreeMap<&str, u64> = BTreeMap::new();
    let mut avg_bins: BTreeMap<String, u64> = BTreeMap::new();
    let mut min_bins: BTreeMap<String, u64> = BTreeMap::new();
    let mut player_hist: BTreeMap<u32, u64> = BTreeMap::new();
    let mut decades: BTreeMap<String, u64> = BTreeMap::new();
    let mut decade_rated: BTreeMap<String, u64> = BTreeMap::new();
    let mut sources: BTreeMap<String, u64> = BTreeMap::new();
    let mut quality: BTreeMap<String, u64> = BTreeMap::new();
    let mut both2200 = 0u64; let mut avg2200 = 0u64; let mut fen = 0u64; let mut variant = 0u64;
    let mut g = G::default(); let mut in_header = false;
    let mut finish = |g: &G, total: &mut u64| {
        *total += 1;
        if g.fen { fen += 1; } if g.variant { variant += 1; }
        *sources.entry(g.source.clone()).or_default() += 1;
        *quality.entry(g.quality.clone()).or_default() += 1;
        let dec = g.year.map(|y| if y < 1950 { "<1950".to_string() } else { format!("{}s", y / 10 * 10) }).unwrap_or("none".into());
        *decades.entry(dec.clone()).or_default() += 1;
        for e in [g.we, g.be].into_iter().flatten() { *player_hist.entry(e / 100 * 100).or_default() += 1; }
        let k = match (g.we, g.be) { (Some(_), Some(_)) => "both", (None, None) => "none", _ => "one" };
        *rated.entry(k).or_default() += 1;
        if let (Some(w), Some(b)) = (g.we, g.be) {
            *decade_rated.entry(dec).or_default() += 1;
            let avg = (w + b) / 2;
            *avg_bins.entry(bin(avg)).or_default() += 1;
            *min_bins.entry(bin(w.min(b))).or_default() += 1;
            if w.min(b) >= 2200 { both2200 += 1; }
            if avg >= 2200 { avg2200 += 1; }
        }
    };
    for line in r.split(b'\n') {
        let line = line.unwrap();
        if line.first() == Some(&b'[') {
            if !in_header { in_header = true; g = G::default(); }
            let s = String::from_utf8_lossy(&line);
            let Some((name, rest)) = s[1..].split_once(' ') else { continue };
            let val = rest.trim_end_matches(|c| c == ']' || c == '\r').trim_matches('"');
            *tags.entry(name.to_string()).or_default() += 1;
            match name {
                "WhiteElo" => g.we = val.parse().ok().filter(|&x| x > 0),
                "BlackElo" => g.be = val.parse().ok().filter(|&x| x > 0),
                "Date" => g.year = val.get(0..4).and_then(|y| y.parse().ok()),
                "FEN" => g.fen = true,
                "SetUp" => g.fen |= val == "1",
                "Variant" => g.variant = !val.eq_ignore_ascii_case("standard"),
                "Source" => g.source = val.to_string(),
                "SourceQuality" => g.quality = val.to_string(),
                _ => {}
            }
        } else if in_header && !line.iter().all(|c| c.is_ascii_whitespace()) {
            in_header = false; finish(&g, &mut total);
        }
    }
    if in_header { finish(&g, &mut total); }
    println!("games: {total}\nfrom FEN/SetUp: {fen}\nnon-standard variant: {variant}");
    println!("\nElo tags: {:?}", rated);
    println!("both rated, min >= 2200: {both2200}; avg >= 2200: {avg2200}");
    println!("\ngames by average Elo (both rated):"); for (k, v) in &avg_bins { println!("  {k:>10} {v:>10}"); }
    println!("\ngames by lower Elo (both rated):"); for (k, v) in &min_bins { println!("  {k:>10} {v:>10}"); }
    println!("\nplayer ratings (per side, 100s):"); for (k, v) in &player_hist { println!("  {k:>5} {v:>10}"); }
    println!("\ngames by decade (all / both rated):"); for (k, v) in &decades { println!("  {k:>6} {v:>10} {:>10}", decade_rated.get(k).unwrap_or(&0)); }
    println!("\nSource:"); for (k, v) in &sources { println!("  {k:>30} {v:>10}"); }
    println!("\nSourceQuality:"); for (k, v) in &quality { println!("  {k:>6} {v:>10}"); }
    println!("\ntags:"); for (k, v) in &tags { println!("  {k:>24} {v:>10}"); }
}
