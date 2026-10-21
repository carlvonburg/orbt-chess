//! Offline coverage tables: explorer stats for one selection, built from Lichess games (blitz
//! or rapid, one Elo bin by the average of both players) or from over-the-board games (one
//! average FIDE rating bin, from Lumbra's Gigabase, CC BY-NC 4.0). A table holds every
//! opponent-to-move position a repertoire can reach with probability ≥ 1/N, down to the
//! database's `min_games`, so coverage needs explorer requests only outside it.
//!
//! File ("OTCB" version 2, little-endian), optionally zstd-compressed:
//!   "OTCB" | u8 version | 3 zero bytes | u32 N | u32 count | u8 name_len | name
//!   count × u32 record offset (from the start of the records); records sorted by EPD bytes
//!   record: u8 epd_len | epd | varint eval | u8 nmoves
//!           nmoves × (u8 move index | varint white | varint draw | varint black | varint eval)
//! The name is the selection, e.g. "rapid_2000-2000" or "otb_2200-2200" (source, first and
//! last bin). A move index is the move's position in the legal moves sorted by UCI. Counts:
//! games per move, by result; a position's total is taken as the sum of its moves. Evals are not
//! used yet.

use std::io::Read;

use super::{ExplorerDatabase, ExplorerMove, ExplorerSpeed, ExplorerStats};
use crate::chess::{ChessPosition, Epd};

const MAGIC: &[u8; 4] = b"OTCB";
const ZSTD_MAGIC: [u8; 4] = [0x28, 0xb5, 0x2f, 0xfd];
const HEADER: usize = 17;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum TableError {
    #[error("not a coverage table")]
    NotATable,
    #[error("coverage table version {0} is not supported")]
    Version(u8),
    #[error("the coverage table is truncated")]
    Truncated,
    #[error("the coverage table could not be decompressed: {0}")]
    Decompress(String),
    #[error("unknown coverage table selection \"{0}\"")]
    Selection(String),
}

/// One table, in memory (39 MB for the largest bin at 1-in-800).
pub struct CoverageTable {
    bytes: Vec<u8>,
    database: ExplorerDatabase,
    target_games: i64,
    count: usize,
    offsets: usize,
    records: usize,
}

impl std::fmt::Debug for CoverageTable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CoverageTable")
            .field("database", &self.database)
            .field("target_games", &self.target_games)
            .field("count", &self.count)
            .finish()
    }
}

impl CoverageTable {
    /// Reads a table file's contents, compressed or not.
    pub fn from_bytes(bytes: Vec<u8>) -> Result<CoverageTable, TableError> {
        let bytes = if bytes.starts_with(&ZSTD_MAGIC) {
            decompress(&bytes)?
        } else {
            bytes
        };
        if bytes.len() < HEADER || &bytes[0..4] != MAGIC {
            return Err(TableError::NotATable);
        }
        if bytes[4] != 2 {
            return Err(TableError::Version(bytes[4]));
        }
        let target_games = u32::from_le_bytes(bytes[8..12].try_into().expect("4 bytes")) as i64;
        let count = u32::from_le_bytes(bytes[12..16].try_into().expect("4 bytes")) as usize;
        let offsets = HEADER + bytes[16] as usize;
        let records = offsets + 4 * count;
        if bytes.len() < records {
            return Err(TableError::Truncated);
        }
        let name = String::from_utf8_lossy(&bytes[HEADER..offsets]).into_owned();
        let database = selection(&name).ok_or(TableError::Selection(name))?;
        Ok(CoverageTable {
            bytes,
            database,
            target_games,
            count,
            offsets,
            records,
        })
    }

    /// The selection the table answers for: one speed and the Elo bins it spans.
    pub fn database(&self) -> &ExplorerDatabase {
        &self.database
    }

    /// The table holds every position needed at 1 in this many games (and any smaller target).
    pub fn target_games(&self) -> i64 {
        self.target_games
    }

    pub fn len(&self) -> usize {
        self.count
    }

    pub fn is_empty(&self) -> bool {
        self.count == 0
    }

    pub fn contains(&self, epd: &Epd) -> bool {
        self.find(epd).is_some()
    }

    /// The position's stats, or None if it is not in the table.
    pub fn stats(&self, epd: &Epd) -> Option<ExplorerStats> {
        let record = self.find(epd)?;
        let position = ChessPosition::from_fen(&epd.query_fen())?;
        let mut legal = position.legal_moves();
        legal.sort_by(|a, b| a.uci.cmp(&b.uci));
        let mut i = 1 + record[0] as usize;
        varint(record, &mut i)?; // the position's eval
        let count = *record.get(i)? as usize;
        i += 1;
        let mut moves = Vec::with_capacity(count);
        for _ in 0..count {
            let index = *record.get(i)? as usize;
            i += 1;
            let (white, draws, black) = (
                varint(record, &mut i)?,
                varint(record, &mut i)?,
                varint(record, &mut i)?,
            );
            varint(record, &mut i)?; // the eval after the move
            let played = legal.get(index)?;
            moves.push(ExplorerMove::new(
                &played.uci,
                &played.san,
                white as i64,
                draws as i64,
                black as i64,
            ));
        }
        moves.sort_by_key(|m| std::cmp::Reverse(m.games()));
        Some(ExplorerStats {
            white: moves.iter().map(|m| m.white).sum(),
            draws: moves.iter().map(|m| m.draws).sum(),
            black: moves.iter().map(|m| m.black).sum(),
            moves,
            opening: None,
        })
    }

    fn find(&self, epd: &Epd) -> Option<&[u8]> {
        let key = epd.as_str().as_bytes();
        let (mut lo, mut hi) = (0, self.count);
        while lo < hi {
            let mid = (lo + hi) / 2;
            let record = self.record(mid)?;
            match record.get(1..1 + record[0] as usize)?.cmp(key) {
                std::cmp::Ordering::Less => lo = mid + 1,
                std::cmp::Ordering::Greater => hi = mid,
                std::cmp::Ordering::Equal => return Some(record),
            }
        }
        None
    }

    fn record(&self, index: usize) -> Option<&[u8]> {
        let at = self.offsets + 4 * index;
        let offset = u32::from_le_bytes(self.bytes.get(at..at + 4)?.try_into().ok()?) as usize;
        self.bytes
            .get(self.records + offset..)
            .filter(|r| !r.is_empty())
    }
}

fn decompress(bytes: &[u8]) -> Result<Vec<u8>, TableError> {
    let error = |e: &dyn std::fmt::Display| TableError::Decompress(e.to_string());
    let mut decoder = ruzstd::decoding::StreamingDecoder::new(bytes).map_err(|e| error(&e))?;
    let mut out = Vec::new();
    decoder.read_to_end(&mut out).map_err(|e| error(&e))?;
    Ok(out)
}

fn varint(bytes: &[u8], i: &mut usize) -> Option<u64> {
    let mut value = 0u64;
    for shift in (0..64).step_by(7) {
        let byte = *bytes.get(*i)?;
        *i += 1;
        value |= ((byte & 0x7f) as u64) << shift;
        if byte < 0x80 {
            return Some(value);
        }
    }
    None
}

/// "rapid_2000-2000" → rapid, the bins from 2000 to 2000.
fn selection(name: &str) -> Option<ExplorerDatabase> {
    let (source, range) = name.split_once('_')?;
    let (low, high) = range.split_once('-')?;
    let (low, high): (i64, i64) = (low.parse().ok()?, high.parse().ok()?);
    let ratings: Vec<i64> = ExplorerDatabase::ELO_BINS
        .into_iter()
        .filter(|b| (low..=high).contains(b))
        .collect();
    if ratings.is_empty() || !ExplorerDatabase::ELO_BINS.contains(&low) {
        return None;
    }
    let speed = match source {
        "otb" => return Some(ExplorerDatabase::Otb { ratings }),
        "blitz" => ExplorerSpeed::Blitz,
        "rapid" => ExplorerSpeed::Rapid,
        _ => return None,
    };
    Some(ExplorerDatabase::Lichess {
        ratings,
        speeds: vec![speed],
    })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    fn put_varint(out: &mut Vec<u8>, mut x: u64) {
        while x >= 0x80 {
            out.push(x as u8 | 0x80);
            x >>= 7;
        }
        out.push(x as u8);
    }

    /// A move in a test table: UCI, white wins, draws, black wins.
    type TestMove<'a> = (&'a str, u64, u64, u64);

    /// A table file with these positions and their moves.
    pub(crate) fn table_bytes(name: &str, n: u32, positions: &[(&Epd, &[TestMove])]) -> Vec<u8> {
        let mut records: Vec<Vec<u8>> = positions
            .iter()
            .map(|(epd, moves)| {
                let position = ChessPosition::from_fen(&epd.query_fen()).unwrap();
                let mut legal: Vec<String> =
                    position.legal_moves().into_iter().map(|m| m.uci).collect();
                legal.sort();
                let mut r = vec![epd.as_str().len() as u8];
                r.extend_from_slice(epd.as_str().as_bytes());
                r.push(0);
                r.push(moves.len() as u8);
                for (uci, w, d, b) in moves.iter() {
                    r.push(legal.iter().position(|m| m == uci).unwrap() as u8);
                    for x in [*w, *d, *b, 0] {
                        put_varint(&mut r, x);
                    }
                }
                r
            })
            .collect();
        records.sort_by(|a, b| a[1..1 + a[0] as usize].cmp(&b[1..1 + b[0] as usize]));
        let mut out = b"OTCB".to_vec();
        out.extend_from_slice(&[2, 0, 0, 0]);
        out.extend_from_slice(&n.to_le_bytes());
        out.extend_from_slice(&(records.len() as u32).to_le_bytes());
        out.push(name.len() as u8);
        out.extend_from_slice(name.as_bytes());
        let mut offset = 0u32;
        for r in &records {
            out.extend_from_slice(&offset.to_le_bytes());
            offset += r.len() as u32;
        }
        for r in records {
            out.extend(r);
        }
        out
    }

    fn after(moves: &[&str]) -> Epd {
        let mut p = ChessPosition::start();
        for m in moves {
            p = p.play_uci(m).unwrap().1;
        }
        p.epd()
    }

    #[test]
    fn reads_stats_by_position() {
        let e4 = after(&["e2e4"]);
        let e4c5 = after(&["e2e4", "c7c5"]);
        let bytes = table_bytes(
            "rapid_2000-2000",
            800,
            &[
                (&e4, &[("e7e5", 30, 10, 20), ("c7c5", 50, 5, 45)]),
                (&e4c5, &[("g1f3", 1, 1, 1)]),
            ],
        );
        let table = CoverageTable::from_bytes(bytes).unwrap();
        assert_eq!(table.len(), 2);
        assert_eq!(table.target_games(), 800);
        assert_eq!(
            *table.database(),
            ExplorerDatabase::Lichess {
                ratings: vec![2000],
                speeds: vec![ExplorerSpeed::Rapid]
            }
        );
        let stats = table.stats(&e4).unwrap();
        assert_eq!((stats.white, stats.draws, stats.black), (80, 15, 65));
        assert_eq!(stats.moves[0].uci, "c7c5");
        assert_eq!(stats.moves[0].san, "c5");
        assert_eq!(stats.share("e7e5"), 60.0 / 160.0);
        assert!(table.stats(&ChessPosition::start().epd()).is_none());
        assert!(table.contains(&e4c5));
    }

    #[test]
    fn rejects_other_files() {
        assert_eq!(
            CoverageTable::from_bytes(b"PGN".to_vec()).unwrap_err(),
            TableError::NotATable
        );
        let bytes = table_bytes("bullet_2000-2000", 800, &[]);
        assert!(matches!(
            CoverageTable::from_bytes(bytes),
            Err(TableError::Selection(_))
        ));
        let bytes = table_bytes("otb_2200-2200", 800, &[]);
        let table = CoverageTable::from_bytes(bytes).unwrap();
        assert_eq!(
            *table.database(),
            ExplorerDatabase::Otb {
                ratings: vec![2200]
            }
        );
        let bytes = table_bytes("blitz_2200-2500", 200, &[]);
        let table = CoverageTable::from_bytes(bytes).unwrap();
        assert_eq!(
            *table.database(),
            ExplorerDatabase::Lichess {
                ratings: vec![2200, 2500],
                speeds: vec![ExplorerSpeed::Blitz]
            }
        );
    }

    /// `OT_COVERAGE_TABLE=<file.otcb.zst> cargo test -p ot-core real_table -- --nocapture`
    #[test]
    fn real_table() {
        let Ok(path) = std::env::var("OT_COVERAGE_TABLE") else {
            return;
        };
        let started = std::time::Instant::now();
        let table = CoverageTable::from_bytes(std::fs::read(path).unwrap()).unwrap();
        println!("{table:?} loaded in {:?}", started.elapsed());
        let e4 = after(&["e2e4"]);
        let stats = table.stats(&e4).expect("1.e4 is in every table");
        println!(
            "after 1.e4: {} games, {:?}",
            stats.total(),
            &stats.moves[..3]
        );
        assert!(stats.share(&stats.moves[0].uci) > 0.2);
    }
}
