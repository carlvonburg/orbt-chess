//! Explorer stats in memory, by database and position. The platform persists them (they can
//! always be fetched again, so they are a local cache, not synced): it loads a database's
//! entries once with `load` and stores what `put` adds. A database may also have an offline
//! coverage table, read for the positions the cache does not have.

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
        if let Some(s) = self.stats.get(&key).and_then(|s| s.get(epd)) {
            return Some(Cow::Borrowed(s));
        }
        self.tables.get(&key)?.stats(epd).map(Cow::Owned)
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
        }
    }
}

/// The stats of one database: fetched from Lichess, else from its offline table.
pub struct DatabaseStats<'a> {
    fetched: Option<&'a HashMap<Epd, ExplorerStats>>,
    table: Option<&'a CoverageTable>,
}

impl StatsSource for DatabaseStats<'_> {
    fn stats(&self, epd: &Epd) -> Option<Cow<'_, ExplorerStats>> {
        if let Some(s) = self.fetched.and_then(|f| f.get(epd)) {
            return Some(Cow::Borrowed(s));
        }
        self.table?.stats(epd).map(Cow::Owned)
    }
}
