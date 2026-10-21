use serde::{Deserialize, Serialize};

use crate::chess::{ChessPosition, Side};

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExplorerMove {
    /// Standard UCI (castling as king two squares), normalized when decoded.
    pub uci: String,
    pub san: String,
    pub white: i64,
    pub draws: i64,
    pub black: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub average_rating: Option<i64>,
}

impl ExplorerMove {
    pub fn new(uci: &str, san: &str, white: i64, draws: i64, black: i64) -> ExplorerMove {
        ExplorerMove {
            uci: uci.to_owned(),
            san: san.to_owned(),
            white,
            draws,
            black,
            average_rating: None,
        }
    }

    pub fn games(&self) -> i64 {
        self.white
            .saturating_add(self.draws)
            .saturating_add(self.black)
    }

    /// Score for `side` in 0...1 (wins + half the draws).
    pub fn score(&self, side: Side) -> f64 {
        if self.games() <= 0 {
            return 0.5;
        }
        let wins = match side {
            Side::White => self.white,
            Side::Black => self.black,
        };
        (wins as f64 + self.draws as f64 / 2.0) / self.games() as f64
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct OpeningName {
    pub eco: String,
    pub name: String,
}

/// Explorer statistics for one position and one database.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ExplorerStats {
    pub white: i64,
    pub draws: i64,
    pub black: i64,
    pub moves: Vec<ExplorerMove>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opening: Option<OpeningName>,
}

/// Game counts above this are not real (Lichess has a few billion games); clamping keeps the
/// sums and shares finite.
const MAX_COUNT: i64 = 1 << 40;

fn clamp_count(n: i64) -> i64 {
    n.clamp(0, MAX_COUNT)
}

impl ExplorerStats {
    pub fn total(&self) -> i64 {
        self.white
            .saturating_add(self.draws)
            .saturating_add(self.black)
    }

    /// With every count in 0...2^40, so a corrupt answer or cache entry cannot give negative
    /// shares or overflow a sum.
    pub fn clamped(mut self) -> ExplorerStats {
        for n in [&mut self.white, &mut self.draws, &mut self.black] {
            *n = clamp_count(*n);
        }
        for m in &mut self.moves {
            for n in [&mut m.white, &mut m.draws, &mut m.black] {
                *n = clamp_count(*n);
            }
        }
        self
    }

    /// Share of games in this position that continued with `uci` (move games / position games).
    /// Uses the move's own counts, so transpositions into the child do not inflate it.
    pub fn share(&self, uci: &str) -> f64 {
        match self.mv(uci) {
            Some(m) if self.total() > 0 => m.games() as f64 / self.total() as f64,
            _ => 0.0,
        }
    }

    pub fn mv(&self, uci: &str) -> Option<&ExplorerMove> {
        self.moves.iter().find(|m| m.uci == uci)
    }

    /// Converts explorer UCI (which may use king-takes-rook castling) into standard UCI
    /// and fixes SAN, by replaying each move on `position`.
    pub fn normalized(&self, position: &ChessPosition) -> ExplorerStats {
        let mut copy = self.clone();
        for m in &mut copy.moves {
            if let Some((played, _)) = position.play_uci(&m.uci) {
                m.uci = played.uci;
                m.san = played.san;
            }
        }
        copy
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ExplorerSpeed {
    UltraBullet,
    Bullet,
    Blitz,
    Rapid,
    Classical,
    Correspondence,
}

impl ExplorerSpeed {
    pub const ALL: [ExplorerSpeed; 6] = [
        ExplorerSpeed::UltraBullet,
        ExplorerSpeed::Bullet,
        ExplorerSpeed::Blitz,
        ExplorerSpeed::Rapid,
        ExplorerSpeed::Classical,
        ExplorerSpeed::Correspondence,
    ];

    /// The Lichess API name, e.g. "ultraBullet".
    pub fn raw(self) -> &'static str {
        match self {
            ExplorerSpeed::UltraBullet => "ultraBullet",
            ExplorerSpeed::Bullet => "bullet",
            ExplorerSpeed::Blitz => "blitz",
            ExplorerSpeed::Rapid => "rapid",
            ExplorerSpeed::Classical => "classical",
            ExplorerSpeed::Correspondence => "correspondence",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            ExplorerSpeed::UltraBullet => "UltraBullet",
            ExplorerSpeed::Bullet => "Bullet",
            ExplorerSpeed::Blitz => "Blitz",
            ExplorerSpeed::Rapid => "Rapid",
            ExplorerSpeed::Classical => "Classical",
            ExplorerSpeed::Correspondence => "Correspondence",
        }
    }
}

/// Which explorer database a repertoire measures coverage against.
///
/// In JSON: `{"masters":{}}`, `{"lichess":{"speeds":[...],"ratings":[...]}}` or
/// `{"otb":{"ratings":[...]}}`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ExplorerDatabase {
    Masters {},
    /// `ratings` are bin lower bounds: Lichess's buckets (0, 1000, 1200, …, 2500), or the
    /// offline tables' finer bins (`ELO_BINS`), which split Lichess's 0 into 0, 600 and 800.
    // Fields in key order, so the JSON keys come out sorted.
    Lichess {
        ratings: Vec<i64>,
        speeds: Vec<ExplorerSpeed>,
    },
    /// Classical (over-the-board) games by average FIDE rating bin (`ELO_BINS`), from an
    /// offline coverage table built from Lumbra's Gigabase. Positions the table lacks come
    /// from the Lichess masters explorer, which has no rating filter.
    Otb {
        ratings: Vec<i64>,
    },
}

impl ExplorerDatabase {
    pub const RATING_BUCKETS: [i64; 9] = [0, 1000, 1200, 1400, 1600, 1800, 2000, 2200, 2500];
    /// The offline coverage tables' Elo bins.
    pub const ELO_BINS: [i64; 11] = [0, 600, 800, 1000, 1200, 1400, 1600, 1800, 2000, 2200, 2500];

    pub fn masters() -> ExplorerDatabase {
        ExplorerDatabase::Masters {}
    }

    pub fn default_lichess() -> ExplorerDatabase {
        ExplorerDatabase::Lichess {
            speeds: vec![
                ExplorerSpeed::Blitz,
                ExplorerSpeed::Rapid,
                ExplorerSpeed::Classical,
            ],
            ratings: vec![1600, 1800, 2000],
        }
    }

    /// Stable key for the stats cache.
    pub fn cache_key(&self) -> String {
        match self {
            ExplorerDatabase::Masters {} => "masters".to_owned(),
            ExplorerDatabase::Lichess { speeds, ratings } => {
                let mut s: Vec<&str> = speeds.iter().map(|s| s.raw()).collect();
                s.sort();
                let mut r = ratings.clone();
                r.sort();
                let r: Vec<String> = r.iter().map(i64::to_string).collect();
                format!("lichess:{}:{}", s.join(","), r.join(","))
            }
            ExplorerDatabase::Otb { ratings } => {
                let mut r = ratings.clone();
                r.sort();
                let r: Vec<String> = r.iter().map(i64::to_string).collect();
                format!("otb:{}", r.join(","))
            }
        }
    }

    pub fn summary(&self) -> String {
        match self {
            ExplorerDatabase::Masters {} => "Masters".to_owned(),
            ExplorerDatabase::Lichess { speeds, ratings } => {
                let s: Vec<&str> = ExplorerSpeed::ALL
                    .iter()
                    .filter(|sp| speeds.contains(sp))
                    .map(|sp| sp.title())
                    .collect();
                let s = s.join(", ");
                let (Some(&low), Some(&high)) = (ratings.iter().min(), ratings.iter().max()) else {
                    return format!("Lichess · {s}");
                };
                let bins: &[i64] = if ratings.iter().all(|r| Self::RATING_BUCKETS.contains(r)) {
                    &Self::RATING_BUCKETS
                } else {
                    &Self::ELO_BINS
                };
                let range = match bins.iter().find(|&&b| b > high) {
                    Some(next) => format!("{low}–{}", next - 1),
                    None => format!("{low}+"),
                };
                format!("Lichess {range} · {s}")
            }
            ExplorerDatabase::Otb { ratings } => match Self::range(ratings, &Self::ELO_BINS) {
                Some(range) => format!("Classical {range}"),
                None => "Classical".to_owned(),
            },
        }
    }

    /// "1600–1799", "2500+" for the bins from the lowest to the highest rating.
    fn range(ratings: &[i64], bins: &[i64]) -> Option<String> {
        let (low, high) = (ratings.iter().min()?, ratings.iter().max()?);
        Some(match bins.iter().find(|&&b| b > *high) {
            Some(next) => format!("{low}–{}", next - 1),
            None => format!("{low}+"),
        })
    }

    /// Query parameters for the explorer endpoint, unencoded.
    pub fn query_items(&self) -> Vec<(&'static str, String)> {
        match self {
            ExplorerDatabase::Masters {} | ExplorerDatabase::Otb { .. } => Vec::new(),
            ExplorerDatabase::Lichess { speeds, ratings } => {
                let s: Vec<&str> = speeds.iter().map(|s| s.raw()).collect();
                // Lichess has no 600 and 800 buckets: they are part of its 0 (under 1000).
                let mut r: Vec<i64> = ratings
                    .iter()
                    .map(|&r| if r < 1000 { 0 } else { r })
                    .collect();
                r.sort();
                r.dedup();
                let r: Vec<String> = r.iter().map(i64::to_string).collect();
                vec![("speeds", s.join(",")), ("ratings", r.join(","))]
            }
        }
    }

    pub fn path(&self) -> &'static str {
        match self {
            ExplorerDatabase::Masters {} | ExplorerDatabase::Otb { .. } => "masters",
            ExplorerDatabase::Lichess { .. } => "lichess",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn database_json_matches_swift() {
        let masters = serde_json::to_string(&ExplorerDatabase::masters()).unwrap();
        assert_eq!(masters, r#"{"masters":{}}"#);
        let lichess = serde_json::to_string(&ExplorerDatabase::default_lichess()).unwrap();
        assert_eq!(
            lichess,
            r#"{"lichess":{"ratings":[1600,1800,2000],"speeds":["blitz","rapid","classical"]}}"#
        );
        let back: ExplorerDatabase = serde_json::from_str(&lichess).unwrap();
        assert_eq!(back, ExplorerDatabase::default_lichess());
    }

    #[test]
    fn counts_are_clamped() {
        let stats = ExplorerStats {
            white: -5,
            draws: i64::MAX,
            black: i64::MAX,
            moves: vec![ExplorerMove::new("e2e4", "e4", i64::MAX, i64::MAX, -1)],
            opening: None,
        };
        assert_eq!(stats.total(), i64::MAX);
        let stats = stats.clamped();
        assert_eq!(
            (stats.white, stats.draws, stats.black),
            (0, 1 << 40, 1 << 40)
        );
        assert_eq!(stats.moves[0].games(), 2 << 40);
        assert_eq!(stats.share("e2e4"), 1.0);
    }

    #[test]
    fn cache_key_and_summary() {
        let db = ExplorerDatabase::Lichess {
            speeds: vec![ExplorerSpeed::Rapid, ExplorerSpeed::Blitz],
            ratings: vec![2000, 1600],
        };
        assert_eq!(db.cache_key(), "lichess:blitz,rapid:1600,2000");
        assert_eq!(db.summary(), "Lichess 1600–2199 · Blitz, Rapid");
        assert_eq!(ExplorerDatabase::masters().cache_key(), "masters");
        let fine = ExplorerDatabase::Lichess {
            speeds: vec![ExplorerSpeed::Rapid],
            ratings: vec![600, 800],
        };
        assert_eq!(fine.summary(), "Lichess 600–999 · Rapid");
        assert_eq!(fine.query_items()[1].1, "0");
        let otb = ExplorerDatabase::Otb {
            ratings: vec![2200],
        };
        assert_eq!(otb.cache_key(), "otb:2200");
        assert_eq!(otb.summary(), "Classical 2200–2499");
        assert_eq!(otb.path(), "masters");
        assert!(otb.query_items().is_empty());
        assert_eq!(
            serde_json::to_string(&otb).unwrap(),
            r#"{"otb":{"ratings":[2200]}}"#
        );
    }

    #[test]
    fn normalizes_king_takes_rook_castling() {
        let p = ChessPosition::from_fen(
            "r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4",
        )
        .unwrap();
        let stats = ExplorerStats {
            white: 1,
            draws: 0,
            black: 0,
            moves: vec![ExplorerMove::new("e1h1", "O-O", 1, 0, 0)],
            opening: None,
        };
        let n = stats.normalized(&p);
        assert_eq!(n.moves[0].uci, "e1g1");
        assert_eq!(n.share("e1g1"), 1.0);
    }
}
