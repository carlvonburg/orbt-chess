//! Explorer stats in memory, by database and position. The platform persists them (they can
//! always be fetched again, so they are a local cache, not synced): it loads a database's
//! entries once with `load` and stores what `put` adds. A database may also have an offline
//! coverage table, read for the positions the cache does not have; for Classical the table
//! comes first (Lichess is only its backup, other games), for Lichess databases fetched stats
//! do (the same games, newer).

use std::borrow::Cow;
use std::collections::{HashMap, HashSet};

use super::table::CoverageTable;
use super::{ExplorerDatabase, ExplorerStats};
use crate::chess::Epd;
use crate::coverage::StatsSource;

#[derive(Debug, Default)]
pub struct StatsCache {
    stats: HashMap<String, HashMap<Epd, ExplorerStats>>,
    loaded: HashSet<String>,
    tables: HashMap<String, CoverageTable>,
}

impl StatsCache {
    pub fn is_loaded(&self, database: &ExplorerDatabase) -> bool {
        self.loaded.contains(&database.cache_key())
    }

    /// The persisted entries of a database (call once, before using it).
    pub fn load(&mut self, database: &ExplorerDatabase, entries: Vec<(Epd, ExplorerStats)>) {
        let key = database.cache_key();
        self.loaded.insert(key.clone());
        let entries = entries.into_iter().map(|(epd, s)| (epd, s.clamped()));
        self.stats.entry(key).or_default().extend(entries);
    }

    pub fn get(&self, database: &ExplorerDatabase, epd: &Epd) -> Option<Cow<'_, ExplorerStats>> {
        let key = database.cache_key();
        lookup(
            self.stats.get(&key),
            self.tables.get(&key),
            table_first(database),
            epd,
        )
    }

    /// Cached stats never expire for now; a table's never change.
    pub fn is_fresh(&self, database: &ExplorerDatabase, epd: &Epd) -> bool {
        let key = database.cache_key();
        self.stats.get(&key).is_some_and(|s| s.contains_key(epd))
            || self.tables.get(&key).is_some_and(|t| t.contains(epd))
    }

    /// Adds (or replaces) the offline table for its database.
    pub fn set_table(&mut self, table: CoverageTable) {
        self.tables.insert(table.database().cache_key(), table);
    }

    pub fn table(&self, database: &ExplorerDatabase) -> Option<&CoverageTable> {
        self.tables.get(&database.cache_key())
    }

    pub fn put(&mut self, database: &ExplorerDatabase, epd: Epd, stats: ExplorerStats) {
        self.stats
            .entry(database.cache_key())
            .or_default()
            .insert(epd, stats.clamped());
    }

    /// Forgets the fetched stats (the tables stay: they are files, not cache).
    pub fn clear(&mut self) {
        self.stats.clear();
        self.loaded.clear();
    }

    /// One database's stats, as the coverage engine reads them.
    pub fn source<'a>(&'a self, database: &ExplorerDatabase) -> DatabaseStats<'a> {
        let key = database.cache_key();
        DatabaseStats {
            fetched: self.stats.get(&key),
            table: self.tables.get(&key),
            table_first: table_first(database),
        }
    }
}

/// The stats of one database: fetched from Lichess and from its offline table, in the
/// database's order.
pub struct DatabaseStats<'a> {
    fetched: Option<&'a HashMap<Epd, ExplorerStats>>,
    table: Option<&'a CoverageTable>,
    table_first: bool,
}

impl StatsSource for DatabaseStats<'_> {
    fn stats(&self, epd: &Epd) -> Option<Cow<'_, ExplorerStats>> {
        lookup(self.fetched, self.table, self.table_first, epd)
    }
}

/// Classical's table comes before stats fetched from Lichess, its backup.
fn table_first(database: &ExplorerDatabase) -> bool {
    matches!(database, ExplorerDatabase::Otb { .. })
}

fn lookup<'a>(
    fetched: Option<&'a HashMap<Epd, ExplorerStats>>,
    table: Option<&CoverageTable>,
    table_first: bool,
    epd: &Epd,
) -> Option<Cow<'a, ExplorerStats>> {
    let fetched = || fetched.and_then(|f| f.get(epd)).map(Cow::Borrowed);
    let table = || table.and_then(|t| t.stats(epd)).map(Cow::Owned);
    if table_first {
        table().or_else(fetched)
    } else {
        fetched().or_else(table)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chess::ChessPosition;
    use crate::explorer::table::tests::table_bytes;

    #[test]
    fn classical_tables_come_before_fetched_stats_lichess_tables_after() {
        let e4 = ChessPosition::start().play_uci("e2e4").unwrap().1.epd();
        let fetched = ExplorerStats {
            white: 1,
            draws: 0,
            black: 0,
            moves: Vec::new(),
            opening: None,
        };
        let mut cache = StatsCache::default();
        for name in ["otb_2000-2000", "rapid_2000-2000"] {
            let bytes = table_bytes(name, 800, &[(&e4, &[("e7e5", 30, 10, 20)])]);
            let table = CoverageTable::from_bytes(bytes).unwrap();
            cache.put(table.database(), e4.clone(), fetched.clone());
            cache.set_table(table);
        }
        let white = |database: ExplorerDatabase| cache.get(&database, &e4).unwrap().white;
        assert_eq!(
            white(ExplorerDatabase::Otb {
                ratings: vec![2000]
            }),
            30
        );
        let rapid = ExplorerDatabase::Lichess {
            ratings: vec![2000],
            speeds: vec![super::super::ExplorerSpeed::Rapid],
        };
        assert_eq!(white(rapid), 1);
    }
}
