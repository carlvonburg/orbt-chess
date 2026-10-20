//! Explorer fetching as a state machine (sans-IO): the platform performs the HTTP requests
//! this hands out and reports the responses; it calls `poll` again at `wake_at` or after any
//! event.
//!
//! The position on screen is fetched once it has stayed on screen for 300 ms (the next focus
//! cancels it). The coverage check goes through a queue: one request in flight, deduplicated,
//! highest priority first, spaced out. Both share the 429 pause (Lichess limits per account):
//! 60 s or Retry-After, kept across launches. A 401 asks for login, offline retries later.

use std::collections::HashMap;

use super::{ExplorerDatabase, ExplorerStats};
use crate::chess::{ChessPosition, Epd};

/// Milliseconds since 1970.
pub type Millis = i64;

/// Lichess publishes no number; nginx limits each user by the tier lila's /auth/check
/// returns. Measured 2026-10-18 with a normal account, cold cache: 0.7 s got a 429 after 28
/// requests, 2 s after 61, while 3.5 s ran 136 without one. Lichess's own explorer crawl
/// script uses 1 s. A 429 slows this down for good.
pub const BASE_INTERVAL_MS: Millis = 1200;
const MAX_INTERVAL_MS: Millis = 10_000;
const FOCUS_DELAY_MS: Millis = 300;
const OFFLINE_RETRY_MS: Millis = 30_000;
const DEFAULT_BAN_MS: Millis = 60_000;

pub const EXPLORER_HOST: &str = "https://explorer.lichess.org";

/// Percent-encodes a query value (unreserved characters, '/' and ',' stay as they are).
fn encode(value: &str) -> String {
    let mut out = String::new();
    for b in value.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' | b',' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// The explorer URL for a position. The platform adds `Authorization: Bearer <token>`.
pub fn explorer_url(epd: &Epd, database: &ExplorerDatabase) -> String {
    let mut query: Vec<(&str, String)> = vec![
        ("fen", epd.query_fen()),
        ("moves", "30".to_owned()),
        ("topGames", "0".to_owned()),
        ("recentGames", "0".to_owned()),
    ];
    query.extend(database.query_items());
    let query: Vec<String> = query
        .iter()
        .map(|(k, v)| format!("{k}={}", encode(v)))
        .collect();
    format!("{EXPLORER_HOST}/{}?{}", database.path(), query.join("&"))
}

/// Decodes an explorer answer and normalizes its moves (standard castling UCI, our SAN).
pub fn decode_stats(body: &[u8], epd: &Epd) -> Option<ExplorerStats> {
    let raw: ExplorerStats = serde_json::from_slice(body).ok()?;
    Some(match ChessPosition::from_fen(&epd.query_fen()) {
        Some(position) => raw.normalized(&position),
        None => raw,
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Lane {
    /// The position on screen.
    Focus,
    /// The background coverage check.
    Coverage,
}

/// A request for the platform to perform.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Fetch {
    pub id: u64,
    pub lane: Lane,
    pub epd: Epd,
    pub database: ExplorerDatabase,
    pub url: String,
}

/// What the platform got back.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Response {
    /// An HTTP answer: status, the Retry-After header in seconds, the body.
    Http {
        status: u16,
        retry_after_secs: Option<i64>,
        body: Vec<u8>,
    },
    /// No answer (offline, timeout).
    Transport,
}

#[derive(Clone, Debug, PartialEq)]
pub enum QueueState {
    Idle,
    Fetching { remaining: usize },
    RateLimited { until: Millis },
    NeedsLogin,
    Offline,
}

/// The result of a response.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Outcome {
    /// New stats to cache (and to tell the repertoires of that database).
    pub stats: Option<(ExplorerDatabase, Epd, ExplorerStats)>,
    /// Lichess rejected the token: sign in again.
    pub unauthorized: bool,
    /// The ban end moved later: persist it, so a relaunch does not restart the penalty.
    pub banned_until: Option<Millis>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Poll {
    pub fetches: Vec<Fetch>,
    /// Call `poll` again at this time (or after any event).
    pub wake_at: Option<Millis>,
}

#[derive(Clone, Debug)]
struct Request {
    epd: Epd,
    database: ExplorerDatabase,
    priority: f64,
}

#[derive(Clone, Debug)]
struct Focus {
    epd: Epd,
    database: ExplorerDatabase,
    due_at: Millis,
    in_flight: Option<u64>,
}

#[derive(Debug)]
pub struct ExplorerQueue {
    interval: Millis,
    banned_until: Option<Millis>,
    pending: HashMap<String, Request>,
    focus: Option<Focus>,
    /// The coverage request in flight: (fetch id, key, start).
    in_flight: Option<(u64, String, Millis)>,
    next_coverage_at: Millis,
    offline_until: Option<Millis>,
    needs_login: bool,
    state: QueueState,
    next_id: u64,
}

fn key(epd: &Epd, database: &ExplorerDatabase) -> String {
    format!("{}|{}", database.cache_key(), epd.as_str())
}

impl ExplorerQueue {
    /// `banned_until`: the persisted end of a ban; `base_interval` overrides the pace (tests).
    pub fn new(banned_until: Option<Millis>, base_interval: Option<Millis>) -> ExplorerQueue {
        ExplorerQueue {
            interval: base_interval.unwrap_or(BASE_INTERVAL_MS),
            banned_until,
            pending: HashMap::new(),
            focus: None,
            in_flight: None,
            next_coverage_at: 0,
            offline_until: None,
            needs_login: false,
            state: QueueState::Idle,
            next_id: 1,
        }
    }

    pub fn state(&self) -> &QueueState {
        &self.state
    }

    /// Coverage requests waiting.
    pub fn remaining(&self) -> usize {
        self.pending.len()
    }

    pub fn interval_ms(&self) -> Millis {
        self.interval
    }

    fn banned(&self, now: Millis) -> Option<Millis> {
        self.banned_until.filter(|&until| until > now)
    }

    // Events

    /// The position on screen, unless its stats are cached and fresh. Replaces the previous
    /// focus; a request already sent still completes (its answer is cached either way).
    pub fn focus(&mut self, epd: Epd, database: ExplorerDatabase, cached: bool, now: Millis) {
        self.focus = (!cached).then_some(Focus {
            epd,
            database,
            due_at: now + FOCUS_DELAY_MS,
            in_flight: None,
        });
    }

    /// Queues stats for the coverage check unless cached; a higher priority is fetched first.
    pub fn request(&mut self, epd: Epd, database: ExplorerDatabase, priority: f64, cached: bool) {
        if cached {
            return;
        }
        let k = key(&epd, &database);
        let entry = self.pending.entry(k).or_insert(Request {
            epd,
            database,
            priority,
        });
        entry.priority = entry.priority.max(priority);
    }

    /// Drops the queued requests of a database (no repertoire of it is showing).
    pub fn cancel_all(&mut self, database: &ExplorerDatabase) {
        self.pending.retain(|_, r| &r.database != database);
        if self.focus.as_ref().is_some_and(|f| f.in_flight.is_none()) {
            self.focus = None;
        }
    }

    /// After signing in or when the network is back.
    pub fn resume(&mut self) {
        if matches!(self.state, QueueState::NeedsLogin | QueueState::Offline) {
            self.state = QueueState::Idle;
        }
        self.needs_login = false;
        self.offline_until = None;
    }

    /// The requests to send now, and when to poll again.
    pub fn poll(&mut self, now: Millis, has_token: bool) -> Poll {
        let mut poll = Poll::default();
        if let Some(until) = self.banned(now) {
            self.state = QueueState::RateLimited { until };
            poll.wake_at = Some(until);
            return poll;
        }
        if matches!(self.state, QueueState::RateLimited { .. }) {
            self.state = QueueState::Idle;
        }
        let mut wake = |t: Millis| {
            poll.wake_at = Some(poll.wake_at.map_or(t, |w| w.min(t)));
        };

        // The position on screen.
        if let Some(focus) = &mut self.focus
            && focus.in_flight.is_none()
        {
            if focus.due_at > now {
                wake(focus.due_at);
            } else if !has_token {
                self.focus = None;
            } else {
                let id = self.next_id;
                self.next_id += 1;
                focus.in_flight = Some(id);
                poll.fetches.push(Fetch {
                    id,
                    lane: Lane::Focus,
                    url: explorer_url(&focus.epd, &focus.database),
                    epd: focus.epd.clone(),
                    database: focus.database.clone(),
                });
            }
        }

        // The coverage check.
        if self.in_flight.is_none() && !self.pending.is_empty() && !self.needs_login {
            let resume_at = self.next_coverage_at.max(self.offline_until.unwrap_or(0));
            if resume_at > now {
                wake(resume_at);
            } else if !has_token {
                self.needs_login = true;
                self.state = QueueState::NeedsLogin;
            } else {
                self.offline_until = None;
                let (k, request) = self
                    .pending
                    .iter()
                    .max_by(|a, b| a.1.priority.total_cmp(&b.1.priority).then(b.0.cmp(a.0)))
                    .map(|(k, r)| (k.clone(), r.clone()))
                    .expect("pending not empty");
                let id = self.next_id;
                self.next_id += 1;
                self.in_flight = Some((id, k, now));
                self.state = QueueState::Fetching {
                    remaining: self.pending.len(),
                };
                poll.fetches.push(Fetch {
                    id,
                    lane: Lane::Coverage,
                    url: explorer_url(&request.epd, &request.database),
                    epd: request.epd,
                    database: request.database,
                });
            }
        } else if self.pending.is_empty()
            && self.in_flight.is_none()
            && matches!(self.state, QueueState::Fetching { .. })
        {
            self.state = QueueState::Idle;
        }
        poll
    }

    /// A response to a fetch from `poll`.
    pub fn on_response(&mut self, fetch: &Fetch, response: Response, now: Millis) -> Outcome {
        let mut outcome = Outcome::default();
        let k = key(&fetch.epd, &fetch.database);
        let is_focus = self
            .focus
            .as_ref()
            .is_some_and(|f| f.in_flight == Some(fetch.id));
        let coverage_start = match &self.in_flight {
            Some((id, _, start)) if *id == fetch.id => Some(*start),
            _ => None,
        };
        // The request is done (not retried after a pause), and whether the next coverage
        // request waits the interval from this one's start.
        let mut finished = true;
        let mut paced = false;
        match response {
            Response::Http {
                status: 200, body, ..
            } => {
                paced = true;
                self.pending.remove(&k);
                if let Some(stats) = decode_stats(&body, &fetch.epd) {
                    outcome.stats = Some((fetch.database.clone(), fetch.epd.clone(), stats));
                }
            }
            Response::Http { status: 401, .. } => {
                outcome.unauthorized = true;
                self.needs_login = true;
                self.state = QueueState::NeedsLogin;
            }
            Response::Http {
                status: 429,
                retry_after_secs,
                ..
            } => {
                self.interval = (self.interval * 3 / 2).min(MAX_INTERVAL_MS);
                let until = now + retry_after_secs.map_or(DEFAULT_BAN_MS, |s| s * 1000);
                if self.banned_until.is_none_or(|b| until > b) {
                    self.banned_until = Some(until);
                    outcome.banned_until = Some(until);
                }
                self.state = QueueState::RateLimited { until };
                // Tried again after the pause.
                finished = false;
            }
            Response::Transport => {
                self.state = QueueState::Offline;
                if coverage_start.is_some() {
                    self.offline_until = Some(now + OFFLINE_RETRY_MS);
                }
            }
            Response::Http { .. } => {
                // Unexpected answer for this position: drop it so the queue keeps moving.
                paced = true;
                self.pending.remove(&k);
            }
        }
        if is_focus {
            match &mut self.focus {
                Some(f) if !finished => f.in_flight = None,
                _ => self.focus = None,
            }
        }
        if let Some(start) = coverage_start {
            self.in_flight = None;
            if finished && paced {
                self.next_coverage_at = start + self.interval;
            }
            if self.pending.is_empty() && matches!(self.state, QueueState::Fetching { .. }) {
                self.state = QueueState::Idle;
            }
        }
        outcome
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> ExplorerDatabase {
        ExplorerDatabase::default_lichess()
    }

    fn epd(line: &str) -> Epd {
        let mut p = ChessPosition::start();
        for m in line.split_whitespace() {
            p = p.play_san(m).unwrap().1;
        }
        p.epd()
    }

    fn ok(body: &str) -> Response {
        Response::Http {
            status: 200,
            retry_after_secs: None,
            body: body.as_bytes().to_vec(),
        }
    }

    const STATS: &str = r#"{"white":10,"draws":5,"black":5,"moves":[{"uci":"e7e5","san":"e5","white":5,"draws":2,"black":3,"averageRating":1900}],"topGames":[],"opening":{"eco":"B00","name":"King's Pawn"}}"#;

    #[test]
    fn url_matches_the_swift_client() {
        let url = explorer_url(&epd("e4"), &db());
        assert_eq!(
            url,
            "https://explorer.lichess.org/lichess?fen=rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR%20b%20KQkq%20-%200%201&moves=30&topGames=0&recentGames=0&speeds=blitz,rapid,classical&ratings=1600,1800,2000"
        );
        assert!(
            explorer_url(&epd(""), &ExplorerDatabase::masters())
                .starts_with("https://explorer.lichess.org/masters?fen=")
        );
    }

    #[test]
    fn focus_waits_300_ms_and_the_next_focus_replaces_it() {
        let mut q = ExplorerQueue::new(None, None);
        q.focus(epd("e4"), db(), false, 0);
        let p = q.poll(0, true);
        assert!(p.fetches.is_empty());
        assert_eq!(p.wake_at, Some(300));
        q.focus(epd("d4"), db(), false, 100);
        let p = q.poll(400, true);
        assert_eq!(p.fetches.len(), 1);
        assert_eq!(p.fetches[0].epd, epd("d4"));
        let out = q.on_response(&p.fetches[0], ok(STATS), 450);
        let (_, e, stats) = out.stats.unwrap();
        assert_eq!(e, epd("d4"));
        assert_eq!(stats.opening.unwrap().name, "King's Pawn");
        assert!(q.poll(500, true).fetches.is_empty());
        // Cached and fresh: nothing to do.
        q.focus(epd("c4"), db(), true, 600);
        assert_eq!(q.poll(1000, true), Poll::default());
    }

    #[test]
    fn coverage_queue_is_deduplicated_prioritized_and_paced() {
        let mut q = ExplorerQueue::new(None, None);
        q.request(epd("e4"), db(), 0.2, false);
        q.request(epd("d4"), db(), 0.5, false);
        q.request(epd("e4"), db(), 0.7, false);
        assert_eq!(q.remaining(), 2);
        let p = q.poll(1_000, true);
        assert_eq!(p.fetches[0].epd, epd("e4"));
        // One at a time.
        assert!(q.poll(1_100, true).fetches.is_empty());
        q.on_response(&p.fetches[0], ok(STATS), 1_300);
        // The next one starts the interval after the previous start.
        let p = q.poll(1_500, true);
        assert!(p.fetches.is_empty());
        assert_eq!(p.wake_at, Some(1_000 + BASE_INTERVAL_MS));
        let p = q.poll(2_200, true);
        assert_eq!(p.fetches[0].epd, epd("d4"));
        q.on_response(&p.fetches[0], ok(STATS), 2_300);
        assert_eq!(q.remaining(), 0);
        q.poll(5_000, true);
        assert_eq!(q.state(), &QueueState::Idle);
    }

    #[test]
    fn a_429_pauses_both_lanes_slows_down_and_retries() {
        let mut q = ExplorerQueue::new(None, None);
        q.request(epd("e4"), db(), 1.0, false);
        let p = q.poll(0, true);
        let out = q.on_response(
            &p.fetches[0],
            Response::Http {
                status: 429,
                retry_after_secs: Some(90),
                body: vec![],
            },
            10,
        );
        assert_eq!(out.banned_until, Some(90_010));
        assert_eq!(q.interval_ms(), BASE_INTERVAL_MS * 3 / 2);
        q.focus(epd("d4"), db(), false, 20);
        let p = q.poll(1_000, true);
        assert!(p.fetches.is_empty());
        assert_eq!(p.wake_at, Some(90_010));
        assert_eq!(q.state(), &QueueState::RateLimited { until: 90_010 });
        let p = q.poll(90_010, true);
        assert_eq!(p.fetches.len(), 2); // the focus and the retried request
        // A ban persisted from an earlier launch holds too.
        let mut q = ExplorerQueue::new(Some(5_000), None);
        q.request(epd("e4"), db(), 1.0, false);
        assert_eq!(q.poll(0, true).wake_at, Some(5_000));
    }

    #[test]
    fn unauthorized_and_offline() {
        let mut q = ExplorerQueue::new(None, None);
        q.request(epd("e4"), db(), 1.0, false);
        // No token: the coverage check waits for a login.
        assert!(q.poll(0, false).fetches.is_empty());
        assert_eq!(q.state(), &QueueState::NeedsLogin);
        assert!(q.poll(10, true).fetches.is_empty());
        q.resume();
        let p = q.poll(20, true);
        let out = q.on_response(
            &p.fetches[0],
            Response::Http {
                status: 401,
                retry_after_secs: None,
                body: vec![],
            },
            30,
        );
        assert!(out.unauthorized);
        assert_eq!(q.state(), &QueueState::NeedsLogin);
        q.resume();
        let p = q.poll(40, true);
        q.on_response(&p.fetches[0], Response::Transport, 50);
        assert_eq!(q.state(), &QueueState::Offline);
        let p = q.poll(60, true);
        assert!(p.fetches.is_empty());
        assert_eq!(p.wake_at, Some(50 + 30_000));
        assert_eq!(q.poll(30_050, true).fetches.len(), 1);
    }
}
