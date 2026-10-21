//! The list of offline coverage tables available for download (`manifest.json` next to the
//! files, written by `scripts/coverage-manifest.py`), and which file a repertoire needs.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::ExplorerDatabase;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CoverageFile {
    /// File name, relative to the manifest.
    pub file: String,
    /// The selection the table answers for: one speed and the Elo bins it spans.
    pub database: ExplorerDatabase,
    /// It holds every position needed at 1 in this many games, or fewer.
    pub target_games: i64,
    pub bytes: i64,
    /// Lowercase hex.
    pub sha256: String,
}

impl CoverageFile {
    /// Whether downloaded bytes are this file.
    pub fn verify(&self, bytes: &[u8]) -> bool {
        bytes.len() as i64 == self.bytes && hex(&Sha256::digest(bytes)) == self.sha256
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoverageManifest {
    pub version: i64,
    pub files: Vec<CoverageFile>,
}

impl CoverageManifest {
    pub fn parse(json: &[u8]) -> Result<CoverageManifest, serde_json::Error> {
        serde_json::from_slice(json)
    }

    /// The file to download for `database`: the deepest one (it holds every smaller target).
    /// None if the database has no table.
    pub fn file_for(&self, database: &ExplorerDatabase) -> Option<&CoverageFile> {
        self.files
            .iter()
            .filter(|f| f.database.cache_key() == database.cache_key())
            .max_by_key(|f| f.target_games)
    }

    /// One entry per database (its deepest file), for listing what can be chosen.
    pub fn selections(&self) -> Vec<&CoverageFile> {
        let mut best: Vec<&CoverageFile> = Vec::new();
        for f in &self.files {
            match best
                .iter_mut()
                .find(|b| b.database.cache_key() == f.database.cache_key())
            {
                Some(b) if b.target_games < f.target_games => *b = f,
                Some(_) => {}
                None => best.push(f),
            }
        }
        best
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::explorer::ExplorerSpeed;

    fn rapid(rating: i64) -> ExplorerDatabase {
        ExplorerDatabase::Lichess {
            ratings: vec![rating],
            speeds: vec![ExplorerSpeed::Rapid],
        }
    }

    fn manifest() -> CoverageManifest {
        CoverageManifest::parse(
            br#"{"version":1,"files":[
              {"file":"rapid_2000-2199_1in200.otcb.zst","database":{"lichess":{"ratings":[2000],"speeds":["rapid"]}},"targetGames":200,"bytes":3,"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
              {"file":"rapid_2000-2199_1in800.otcb.zst","database":{"lichess":{"ratings":[2000],"speeds":["rapid"]}},"targetGames":800,"bytes":9,"sha256":"00"},
              {"file":"rapid_1600-1799_1in800.otcb.zst","database":{"lichess":{"ratings":[1600],"speeds":["rapid"]}},"targetGames":800,"bytes":9,"sha256":"00"}
            ]}"#,
        )
        .unwrap()
    }

    #[test]
    fn chooses_the_deepest_file() {
        let m = manifest();
        assert_eq!(m.file_for(&rapid(2000)).unwrap().target_games, 800);
        assert!(m.file_for(&rapid(1400)).is_none());
        let selections: Vec<i64> = m.selections().iter().map(|f| f.target_games).collect();
        assert_eq!(selections, [800, 800]);
    }

    #[test]
    fn verifies_size_and_hash() {
        let f = &manifest().files[0];
        assert!(f.verify(b"abc"));
        assert!(!f.verify(b"abd"));
        assert!(!f.verify(b"abcd"));
    }
}
