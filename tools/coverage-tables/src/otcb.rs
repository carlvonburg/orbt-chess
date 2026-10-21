//! Per-bin coverage table ("OTCB"): one Elo bin / speed selection, keyed by FEN, sorted so a
//! reader can binary-search it. Depends only on shakmaty, so the app's Rust core can use it as is.
//!
//! Layout (little-endian):
//!   "OTCB" | u8 version = 2 | 3 bytes zero | u32 N | u32 count | u8 name_len | name
//!   count x u32: record offset, relative to the start of the records; records sorted by FEN bytes
//!   record: u8 fen_len | fen | varint eval | u8 nmoves
//!           nmoves x (u8 move index | varint white | varint draw | varint black | varint eval)
//!
//! FEN: the first 4 fields (pieces, turn, castling, ep), ep only when an en-passant capture is legal.
//! Move index: position in the legal moves sorted by UCI string (standard castling, e.g. e1g1).
//! Counts: games in the selection that reached the position after the move, by result.
//! Eval: Stockfish eval (first PV) of the record's position / of the position after the move, from
//! White's point of view. Varint: 0 = none, else
//! ((zigzag(score) << 1) | is_mate) + 1; score is centipawns, or moves to mate.
use shakmaty::{fen::Fen, CastlingMode, Chess, EnPassantMode, Move, Position};

const MAGIC: &[u8; 4] = b"OTCB";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Eval { Cp(i32), Mate(i32) }

impl Eval {
    fn encode(e: Option<Eval>) -> u64 {
        let (v, mate) = match e { None => return 0, Some(Eval::Cp(v)) => (v, 0), Some(Eval::Mate(v)) => (v, 1) };
        let zz = ((v << 1) ^ (v >> 31)) as u32 as u64;
        ((zz << 1) | mate) + 1
    }

    fn decode(x: u64) -> Option<Eval> {
        if x == 0 { return None; }
        let x = x - 1;
        let zz = (x >> 1) as u32;
        let v = ((zz >> 1) as i32) ^ -((zz & 1) as i32);
        Some(if x & 1 == 1 { Eval::Mate(v) } else { Eval::Cp(v) })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MoveStats { pub index: u8, pub white: u64, pub draw: u64, pub black: u64, pub eval: Option<Eval> }

/// A position's entry: its own eval and its moves.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry { pub eval: Option<Eval>, pub moves: Vec<MoveStats> }

impl MoveStats {
    pub fn games(&self) -> u64 { self.white + self.draw + self.black }
}

/// The table key of a position.
pub fn fen_key(pos: &Chess) -> String {
    let fen = Fen::from_position(pos, EnPassantMode::Legal).to_string();
    fen.split(' ').take(4).collect::<Vec<_>>().join(" ")
}

/// Legal moves in the order move indexes refer to.
pub fn sorted_moves(pos: &Chess) -> Vec<Move> {
    let mut moves: Vec<_> = pos.legal_moves().into_iter().map(|m| (m.to_uci(CastlingMode::Standard).to_string(), m)).collect();
    moves.sort_by(|a, b| a.0.cmp(&b.0));
    moves.into_iter().map(|x| x.1).collect()
}

fn put_varint(out: &mut Vec<u8>, mut x: u64) {
    while x >= 0x80 { out.push(x as u8 | 0x80); x >>= 7; }
    out.push(x as u8);
}

fn get_varint(b: &[u8], i: &mut usize) -> Option<u64> {
    let mut x = 0u64;
    for shift in (0..64).step_by(7) {
        let byte = *b.get(*i)?;
        *i += 1;
        x |= ((byte & 0x7f) as u64) << shift;
        if byte < 0x80 { return Some(x); }
    }
    None
}

pub fn encode_record(fen: &str, e: &Entry) -> Vec<u8> {
    let mut r = Vec::with_capacity(4 + fen.len() + e.moves.len() * 7);
    r.push(fen.len() as u8);
    r.extend_from_slice(fen.as_bytes());
    put_varint(&mut r, Eval::encode(e.eval));
    r.push(e.moves.len() as u8);
    for m in &e.moves {
        r.push(m.index);
        put_varint(&mut r, m.white);
        put_varint(&mut r, m.draw);
        put_varint(&mut r, m.black);
        put_varint(&mut r, Eval::encode(m.eval));
    }
    r
}

/// Writes records (each from `encode_record`) sorted by FEN; returns the file size.
pub fn write(path: &str, n: u32, name: &str, mut records: Vec<Vec<u8>>) -> std::io::Result<u64> {
    use std::io::Write;
    records.sort_by(|a, b| a[1..1 + a[0] as usize].cmp(&b[1..1 + b[0] as usize]));
    let mut f = std::io::BufWriter::new(std::fs::File::create(path)?);
    f.write_all(MAGIC)?;
    f.write_all(&[2, 0, 0, 0])?;
    f.write_all(&n.to_le_bytes())?;
    f.write_all(&(records.len() as u32).to_le_bytes())?;
    f.write_all(&[name.len() as u8])?;
    f.write_all(name.as_bytes())?;
    let mut off = 0u32;
    for r in &records {
        f.write_all(&off.to_le_bytes())?;
        off = off.checked_add(r.len() as u32).expect("records > 4 GB");
    }
    for r in &records { f.write_all(r)?; }
    f.flush()?;
    Ok(17 + name.len() as u64 + 4 * records.len() as u64 + off as u64)
}

/// A table over the file's bytes (e.g. mmap'd or read into memory).
pub struct Table<'a> { pub n: u32, pub name: &'a str, count: usize, offsets: &'a [u8], records: &'a [u8] }

impl<'a> Table<'a> {
    pub fn parse(b: &'a [u8]) -> Result<Table<'a>, &'static str> {
        if b.len() < 17 || &b[0..4] != MAGIC { return Err("not an OTCB file"); }
        if b[4] != 2 { return Err("unsupported version"); }
        let n = u32::from_le_bytes(b[8..12].try_into().unwrap());
        let count = u32::from_le_bytes(b[12..16].try_into().unwrap()) as usize;
        let name_end = 17 + b[16] as usize;
        let off_end = name_end + 4 * count;
        if b.len() < off_end { return Err("truncated"); }
        let name = std::str::from_utf8(&b[17..name_end]).map_err(|_| "bad name")?;
        Ok(Table { n, name, count, offsets: &b[name_end..off_end], records: &b[off_end..] })
    }

    pub fn len(&self) -> usize { self.count }

    fn record(&self, i: usize) -> &'a [u8] {
        let o = u32::from_le_bytes(self.offsets[4 * i..4 * i + 4].try_into().unwrap()) as usize;
        &self.records[o..]
    }

    fn fen_at(&self, i: usize) -> &'a [u8] {
        let r = self.record(i);
        &r[1..1 + r[0] as usize]
    }

    /// Moves of the position with this table key, or None if it is not in the table.
    pub fn get(&self, fen: &str) -> Option<Entry> {
        let (mut lo, mut hi) = (0, self.count);
        while lo < hi {
            let mid = (lo + hi) / 2;
            match self.fen_at(mid).cmp(fen.as_bytes()) {
                std::cmp::Ordering::Less => lo = mid + 1,
                std::cmp::Ordering::Greater => hi = mid,
                std::cmp::Ordering::Equal => return decode(self.record(mid)),
            }
        }
        None
    }

    /// The position's eval and its moves resolved to legal moves.
    pub fn lookup(&self, pos: &Chess) -> Option<(Option<Eval>, Vec<(Move, MoveStats)>)> {
        let e = self.get(&fen_key(pos))?;
        let legal = sorted_moves(pos);
        let moves = e.moves.into_iter().map(|s| legal.get(s.index as usize).map(|m| (m.clone(), s))).collect::<Option<_>>()?;
        Some((e.eval, moves))
    }

    /// All records' keys, in file order (for tests and tooling).
    pub fn fens(&self) -> impl Iterator<Item = &'a [u8]> + '_ { (0..self.count).map(|i| self.fen_at(i)) }
}

fn decode(r: &[u8]) -> Option<Entry> {
    let mut i = 1 + r[0] as usize;
    let eval = Eval::decode(get_varint(r, &mut i)?);
    let nm = *r.get(i)? as usize;
    i += 1;
    let mut v = Vec::with_capacity(nm);
    for _ in 0..nm {
        let index = *r.get(i)?;
        i += 1;
        let white = get_varint(r, &mut i)?;
        let draw = get_varint(r, &mut i)?;
        let black = get_varint(r, &mut i)?;
        let eval = Eval::decode(get_varint(r, &mut i)?);
        v.push(MoveStats { index, white, draw, black, eval });
    }
    Some(Entry { eval, moves: v })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let start = Chess::default();
        let mut e4 = start.clone();
        e4.play_unchecked(sorted_moves(&start).into_iter().find(|m| m.to_uci(CastlingMode::Standard).to_string() == "e2e4").unwrap());
        assert_eq!(fen_key(&e4), "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -");
        let a = Entry { eval: Some(Eval::Cp(18)), moves: vec![MoveStats { index: 3, white: 5, draw: 300, black: 1 << 40, eval: Some(Eval::Mate(-3)) }] };
        let b = Entry { eval: None, moves: vec![
            MoveStats { index: 0, white: 1, draw: 0, black: 2, eval: Some(Eval::Cp(-32768)) },
            MoveStats { index: 7, white: 9, draw: 9, black: 9, eval: None },
        ] };
        for e in [None, Some(Eval::Cp(0)), Some(Eval::Cp(-1)), Some(Eval::Cp(32767)), Some(Eval::Mate(1)), Some(Eval::Mate(-1))] {
            assert_eq!(Eval::decode(Eval::encode(e)), e);
        }
        let path = std::env::temp_dir().join("otcb_roundtrip_test.otcb");
        let path = path.to_str().unwrap();
        write(path, 800, "test", vec![encode_record(&fen_key(&e4), &a), encode_record(&fen_key(&start), &b)]).unwrap();
        let bytes = std::fs::read(path).unwrap();
        let t = Table::parse(&bytes).unwrap();
        assert_eq!((t.n, t.name, t.len()), (800, "test", 2));
        assert_eq!(t.get(&fen_key(&e4)), Some(a));
        assert_eq!(t.get(&fen_key(&start)), Some(b));
        assert_eq!(t.get("8/8/8/8/8/8/8/8 w - -"), None);
        let fens: Vec<_> = t.fens().collect();
        assert!(fens.windows(2).all(|w| w[0] < w[1]));
        std::fs::remove_file(path).unwrap();
    }
}
