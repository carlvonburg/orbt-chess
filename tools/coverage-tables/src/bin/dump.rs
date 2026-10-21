//! Prints per-move game counts, summed over tables, for lines given as UCI, as JSON lines:
//! dump <file.otcb.zst>... -- "<uci moves>"...
#[path = "../otcb.rs"]
#[allow(dead_code)]
mod otcb;
use shakmaty::{uci::UciMove, CastlingMode, Chess, Position};
use std::collections::BTreeMap;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let sep = args.iter().position(|a| a == "--").unwrap();
    let files: Vec<Vec<u8>> = args[..sep].iter().map(|f| zstd::decode_all(std::fs::File::open(f).unwrap()).unwrap()).collect();
    let tables: Vec<_> = files.iter().map(|b| otcb::Table::parse(b).unwrap()).collect();
    for line in &args[sep + 1..] {
        let mut pos = Chess::default();
        for u in line.split_whitespace() { let m = u.parse::<UciMove>().unwrap().to_move(&pos).unwrap(); pos.play_unchecked(m); }
        let mut moves: BTreeMap<String, u64> = BTreeMap::new();
        let mut found = false;
        for t in &tables {
            if let Some((_, ms)) = t.lookup(&pos) { found = true; for (m, s) in ms { *moves.entry(m.to_uci(CastlingMode::Standard).to_string()).or_default() += s.games(); } }
        }
        let body: Vec<String> = moves.iter().map(|(k, v)| format!("\"{k}\":{v}")).collect();
        println!("{{\"line\":\"{line}\",\"found\":{found},\"moves\":{{{}}}}}", body.join(","));
    }
}
