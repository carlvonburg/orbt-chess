//! Reads OTCB .zst tables back and prints positions: verify <file.otcb.zst>... (lines as UCI after "--")
#[path = "../otcb.rs"]
#[allow(dead_code)]
mod otcb;
use shakmaty::{san::San, uci::UciMove, CastlingMode, Chess, Position};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let sep = args.iter().position(|a| a == "--").unwrap_or(args.len());
    let lines: Vec<&str> = args.get(sep + 1..).unwrap_or(&[]).iter().map(|s| s.as_str()).collect();
    for f in &args[..sep] {
        let bytes = zstd::decode_all(std::fs::File::open(f).unwrap()).unwrap();
        let t = otcb::Table::parse(&bytes).unwrap();
        let fens: Vec<_> = t.fens().collect();
        assert!(fens.windows(2).all(|w| w[0] < w[1]), "not sorted");
        let mut bad = 0;
        for fen in &fens { if t.get(std::str::from_utf8(fen).unwrap()).is_none() { bad += 1; } }
        println!("{f}: name {} N {} positions {} raw {} undecodable {bad}", t.name, t.n, t.len(), bytes.len());
        for line in &lines {
            let mut pos = Chess::default();
            let mut sans = Vec::new();
            for u in line.split_whitespace() {
                let m = u.parse::<UciMove>().unwrap().to_move(&pos).unwrap();
                sans.push(San::from_move(&pos, m.clone()).to_string());
                pos.play_unchecked(m);
            }
            let Some((_, moves)) = t.lookup(&pos) else { println!("  {:<22} not in table", sans.join(" ")); continue };
            let total: u64 = moves.iter().map(|m| m.1.games()).sum();
            let mut moves = moves;
            moves.sort_by_key(|m| std::cmp::Reverse(m.1.games()));
            let top: Vec<String> = moves.iter().take(6).map(|(m, s)| format!("{} {:.1}%", San::from_move(&pos, m.clone()), 100.0 * s.games() as f64 / total as f64)).collect();
            let _ = CastlingMode::Standard;
            println!("  {:<22} {:>8} games: {}", if sans.is_empty() { "start".into() } else { sans.join(" ") }, total, top.join(", "));
        }
    }
}
