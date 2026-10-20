//! Explorer stats in memory, by database and position. The platform persists them (they can
//! always be fetched again, so they are a local cache, not synced): it loads a database's
//! entries once with `load` and stores what `put` adds.

use std::collections::{HashMap, HashSet};

use super::{ExplorerDatabase, ExplorerStats};
use crate::chess::Epd;
use crate::coverage::StatsSource;

#[derive(Debug, Default)]
pub struct StatsCache {
    stats: HashMap<String, HashMap<Epd, ExplorerStats>>,
    loaded: HashSet<String>,
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

    pub fn get(&self, database: &ExplorerDatabase, epd: &Epd) -> Option<&ExplorerStats> {
        self.stats.get(&database.cache_key())?.get(epd)
    }

    /// Cached stats never expire for now.
    pub fn is_fresh(&self, database: &ExplorerDatabase, epd: &Epd) -> bool {
        self.get(database, epd).is_some()
    }

    pub fn put(&mut self, database: &ExplorerDatabase, epd: Epd, stats: ExplorerStats) {
        self.stats
            .entry(database.cache_key())
            .or_default()
            .insert(epd, stats.clamped());
    }

    pub fn clear(&mut self) {
        self.stats.clear();
        self.loaded.clear();
    }

    /// One database's stats, as the coverage engine reads them.
    pub fn source<'a>(&'a self, database: &ExplorerDatabase) -> DatabaseStats<'a> {
        DatabaseStats(self.stats.get(&database.cache_key()))
    }
}

/// The stats of one database.
pub struct DatabaseStats<'a>(Option<&'a HashMap<Epd, ExplorerStats>>);

impl StatsSource for DatabaseStats<'_> {
    fn stats(&self, epd: &Epd) -> Option<&ExplorerStats> {
        self.0?.get(epd)
    }
}
