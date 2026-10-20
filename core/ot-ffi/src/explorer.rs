use std::sync::{Arc, Mutex, Weak};

use ot_core::chess::Epd;
use ot_core::explorer::cache::StatsCache;
use ot_core::explorer::queue::{self, ExplorerQueue, Lane, QueueState};
use ot_core::explorer::{ExplorerDatabase, ExplorerStats};

use crate::document::RepertoireDoc;

/// Where the platform keeps explorer stats between launches (a local, unsynced cache).
#[uniffi::export(with_foreign)]
pub trait StatsStore: Send + Sync {
    /// Every stored entry of a database (by its cache key): (EPD, the stats as JSON).
    fn load(&self, database_key: String) -> Vec<StoredStats>;
    fn save(&self, database_key: String, epd: Epd, json: Vec<u8>);
}

/// Told when there is fetching to do: call `Explorer::poll`.
#[uniffi::export(with_foreign)]
pub trait ExplorerListener: Send + Sync {
    fn wake(&self);
}

#[derive(uniffi::Record)]
pub struct StoredStats {
    pub epd: Epd,
    pub json: Vec<u8>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct Fetch {
    pub id: u64,
    pub lane: Lane,
    pub epd: Epd,
    pub database: ExplorerDatabase,
    pub url: String,
}

#[derive(uniffi::Record)]
pub struct Poll {
    pub fetches: Vec<Fetch>,
    /// Milliseconds since 1970: poll again then (or after any event).
    pub wake_at: Option<i64>,
}

#[derive(uniffi::Record, Default)]
pub struct FetchOutcome {
    /// Lichess rejected the token: sign in again.
    pub unauthorized: bool,
    /// Persist this end of a ban (milliseconds since 1970).
    pub banned_until: Option<i64>,
}

struct Inner {
    cache: StatsCache,
    queue: ExplorerQueue,
    documents: Vec<Weak<RepertoireDoc>>,
}

/// Explorer stats for every repertoire: the cache, and the fetch queue the platform runs.
#[derive(uniffi::Object)]
pub struct Explorer {
    inner: Mutex<Inner>,
    store: Arc<dyn StatsStore>,
    listener: Mutex<Option<Arc<dyn ExplorerListener>>>,
}

impl Explorer {
    pub(crate) fn with_stats<R>(
        &self,
        database: &ExplorerDatabase,
        f: impl FnOnce(&dyn ot_core::coverage::StatsSource) -> R,
    ) -> R {
        self.ensure_loaded(database.clone());
        let inner = self.inner.lock().expect("explorer lock");
        f(&inner.cache.source(database))
    }

    pub(crate) fn register(&self, doc: &Arc<RepertoireDoc>) {
        let mut inner = self.inner.lock().expect("explorer lock");
        inner.documents.retain(|d| d.strong_count() > 0);
        inner.documents.push(Arc::downgrade(doc));
    }

    /// Queues the coverage requests of a repertoire and wakes the platform.
    pub(crate) fn request_all(&self, database: &ExplorerDatabase, requests: Vec<(Epd, f64)>) {
        if requests.is_empty() {
            return;
        }
        {
            let mut inner = self.inner.lock().expect("explorer lock");
            for (epd, priority) in requests {
                let cached = inner.cache.is_fresh(database, &epd);
                inner.queue.request(epd, database.clone(), priority, cached);
            }
        }
        self.wake();
    }

    fn wake(&self) {
        let listener = self.listener.lock().expect("listener lock").clone();
        if let Some(l) = listener {
            l.wake();
        }
    }
}

#[uniffi::export]
impl Explorer {
    /// `banned_until`: the persisted end of a ban; `base_interval_ms` overrides the pace.
    #[uniffi::constructor]
    pub fn new(
        store: Arc<dyn StatsStore>,
        banned_until: Option<i64>,
        base_interval_ms: Option<i64>,
    ) -> Arc<Explorer> {
        Arc::new(Explorer {
            inner: Mutex::new(Inner {
                cache: StatsCache::default(),
                queue: ExplorerQueue::new(banned_until, base_interval_ms),
                documents: Vec::new(),
            }),
            store,
            listener: Mutex::new(None),
        })
    }

    pub fn set_listener(&self, listener: Arc<dyn ExplorerListener>) {
        *self.listener.lock().expect("listener lock") = Some(listener);
    }

    /// Loads a database's stored stats once.
    pub fn ensure_loaded(&self, database: ExplorerDatabase) {
        if self
            .inner
            .lock()
            .expect("explorer lock")
            .cache
            .is_loaded(&database)
        {
            return;
        }
        let entries: Vec<(Epd, ExplorerStats)> = self
            .store
            .load(database.cache_key())
            .into_iter()
            .filter_map(|s| Some((s.epd, serde_json::from_slice(&s.json).ok()?)))
            .collect();
        self.inner
            .lock()
            .expect("explorer lock")
            .cache
            .load(&database, entries);
    }

    pub fn stats(&self, database: ExplorerDatabase, epd: Epd) -> Option<ExplorerStats> {
        self.ensure_loaded(database.clone());
        self.inner
            .lock()
            .expect("explorer lock")
            .cache
            .get(&database, &epd)
            .cloned()
    }

    /// Forgets the stats in memory (after the platform cleared its store).
    pub fn clear(&self) {
        self.inner.lock().expect("explorer lock").cache.clear();
    }

    pub fn state(&self) -> QueueState {
        self.inner
            .lock()
            .expect("explorer lock")
            .queue
            .state()
            .clone()
    }

    /// Coverage requests waiting.
    pub fn remaining(&self) -> u64 {
        self.inner.lock().expect("explorer lock").queue.remaining() as u64
    }

    /// The position on screen.
    pub fn focus(&self, epd: Epd, database: ExplorerDatabase, now_ms: i64) {
        self.ensure_loaded(database.clone());
        {
            let mut inner = self.inner.lock().expect("explorer lock");
            let cached = inner.cache.is_fresh(&database, &epd);
            inner.queue.focus(epd, database, cached, now_ms);
        }
        self.wake();
    }

    pub fn cancel_all(&self, database: ExplorerDatabase) {
        self.inner
            .lock()
            .expect("explorer lock")
            .queue
            .cancel_all(&database);
    }

    /// After signing in or when the network is back.
    pub fn resume(&self) {
        self.inner.lock().expect("explorer lock").queue.resume();
        self.wake();
    }

    /// The requests to send now (with `Authorization: Bearer <token>`), and when to poll again.
    pub fn poll(&self, now_ms: i64, has_token: bool) -> Poll {
        let p = self
            .inner
            .lock()
            .expect("explorer lock")
            .queue
            .poll(now_ms, has_token);
        Poll {
            fetches: p
                .fetches
                .into_iter()
                .map(|f| Fetch {
                    id: f.id,
                    lane: f.lane,
                    epd: f.epd,
                    database: f.database,
                    url: f.url,
                })
                .collect(),
            wake_at: p.wake_at,
        }
    }

    /// An HTTP answer (`status` None: no answer, e.g. offline).
    pub fn on_response(
        &self,
        fetch: Fetch,
        status: Option<u16>,
        retry_after_secs: Option<i64>,
        body: Vec<u8>,
        now_ms: i64,
    ) -> FetchOutcome {
        let response = match status {
            Some(status) => queue::Response::Http {
                status,
                retry_after_secs,
                body,
            },
            None => queue::Response::Transport,
        };
        let core_fetch = queue::Fetch {
            id: fetch.id,
            lane: fetch.lane,
            epd: fetch.epd.clone(),
            database: fetch.database.clone(),
            url: fetch.url.clone(),
        };
        let (outcome, documents) = {
            let mut inner = self.inner.lock().expect("explorer lock");
            let outcome = inner.queue.on_response(&core_fetch, response, now_ms);
            if let Some((db, epd, stats)) = &outcome.stats {
                inner.cache.put(db, epd.clone(), stats.clone());
            }
            let documents: Vec<Arc<RepertoireDoc>> =
                inner.documents.iter().filter_map(Weak::upgrade).collect();
            (outcome, documents)
        };
        if let Some((db, epd, stats)) = &outcome.stats {
            if let Ok(json) = serde_json::to_vec(stats) {
                self.store.save(db.cache_key(), epd.clone(), json);
            }
            // Outside the explorer lock: documents read the cache under their own lock.
            for doc in documents {
                doc.stats_arrived(db, epd);
            }
        }
        self.wake();
        FetchOutcome {
            unauthorized: outcome.unauthorized,
            banned_until: outcome.banned_until,
        }
    }
}
