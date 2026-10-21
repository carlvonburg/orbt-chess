//! Explorer fetching as a state machine (sans-IO): the platform sends the HTTP requests this
//! hands out (token included) and reports the responses; it calls `poll` again at `wake_at` or after any
//! event.
//!
//! The position on screen is fetched once it has stayed on screen for 300 ms (the next focus
//! cancels it). The coverage check goes through a queue: one request in flight, deduplicated,
//! highest priority first, spaced out. Both share the 429 pause (Lichess limits per account):
//! 60 s or Retry-After, kept across launches. A 401 asks for login, offline retries later.
//! While a database's offline table is downloading, nothing is fetched for it (`hold`): the
//! table answers most of it, and fetched stats would be kept over the table's.

use std::collections::{HashMap, HashSet};

use super::{ExplorerDatabase, ExplorerStats};
use crate::chess::{ChessPosition, Epd};
use crate::http::{HttpRequest, HttpResponse, query_encode};

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
const TIMEOUT_SECS: u32 = 20;

pub const EXPLORER_HOST: &str = "https://explorer.lichess.org";

/// The explorer URL for a position.
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
        .map(|(k, v)| format!("{k}={}", query_encode(v)))
        .collect();
    format!("{EXPLORER_HOST}/{}?{}", database.path(), query.join("&"))
}

/// The explorer request for a position, with the Lichess token.
pub fn explorer_request(epd: &Epd, database: &ExplorerDatabase, token: &str) -> HttpRequest {
    HttpRequest::get(explorer_url(epd, database))
        .bearer(token)
        .timeout(TIMEOUT_SECS)
}

/// Decodes an explorer answer and normalizes its moves (standard castling UCI, our SAN).
pub fn decode_stats(body: &[u8], epd: &Epd) -> Option<ExplorerStats> {
    let raw = serde_json::from_slice::<ExplorerStats>(body)
        .ok()?
        .clamped();
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
    pub request: HttpRequest,
}

#[derive(Clone, Debug, PartialEq)]
pub enum QueueState {
    Idle,
    Fetching { remaining: u64 },
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
    /// Databases (cache keys) whose offline table is on its way.
    held: HashSet<String>,
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
            held: HashSet::new(),
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

    /// Drops the requests of `database` that `answered` says need no fetch any more (an
    /// offline table now holds them).
    pub fn drop_answered(&mut self, database: &ExplorerDatabase, answered: impl Fn(&Epd) -> bool) {
        self.pending
            .retain(|_, r| &r.database != database || !answered(&r.epd));
        if self
            .focus
            .as_ref()
            .is_some_and(|f| f.in_flight.is_none() && &f.database == database && answered(&f.epd))
        {
            self.focus = None;
        }
    }

    /// Fetches nothing for `database` until `release`: its offline table is downloading.
    pub fn hold(&mut self, database: &ExplorerDatabase) {
        self.held.insert(database.cache_key());
    }

    /// The table arrived (call `drop_answered` first) or could not be had: fetch again.
    pub fn release(&mut self, database: &ExplorerDatabase) {
        self.held.remove(&database.cache_key());
    }

    fn is_held(&self, database: &ExplorerDatabase) -> bool {
        self.held.contains(&database.cache_key())
    }

    /// After signing in or when the network is back.
    pub fn resume(&mut self) {
        if matches!(self.state, QueueState::NeedsLogin | QueueState::Offline) {
            self.state = QueueState::Idle;
        }
        self.needs_login = false;
        self.offline_until = None;
    }

    /// The requests to send now, and when to poll again. `token`: the Lichess token, if
    /// signed in (the explorer needs one).
    pub fn poll(&mut self, now: Millis, token: Option<&str>) -> Poll {
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
        let focus_held = self
            .focus
            .as_ref()
            .is_some_and(|f| self.is_held(&f.database));
        if let Some(focus) = &mut self.focus
            && focus.in_flight.is_none()
            && !focus_held
        {
            if focus.due_at > now {
                wake(focus.due_at);
            } else if let Some(token) = token {
                let id = self.next_id;
                self.next_id += 1;
                focus.in_flight = Some(id);
                poll.fetches.push(Fetch {
                    id,
                    lane: Lane::Focus,
                    request: explorer_request(&focus.epd, &focus.database, token),
                    epd: focus.epd.clone(),
                    database: focus.database.clone(),
                });
            } else {
                self.focus = None;
            }
        }

        // The coverage check.
        let next = self
            .pending
            .iter()
            .filter(|(_, r)| !self.is_held(&r.database))
            .max_by(|a, b| a.1.priority.total_cmp(&b.1.priority).then(b.0.cmp(a.0)))
            .map(|(k, r)| (k.clone(), r.clone()));
        let has_next = next.is_some();
        if self.in_flight.is_none()
            && let Some((k, request)) = next
            && !self.needs_login
        {
            let resume_at = self.next_coverage_at.max(self.offline_until.unwrap_or(0));
            if resume_at > now {
                wake(resume_at);
            } else if let Some(token) = token {
                self.offline_until = None;
                let id = self.next_id;
                self.next_id += 1;
                self.in_flight = Some((id, k, now));
                self.state = QueueState::Fetching {
                    remaining: self.pending.len() as u64,
                };
                poll.fetches.push(Fetch {
                    id,
                    lane: Lane::Coverage,
                    request: explorer_request(&request.epd, &request.database, token),
                    epd: request.epd,
                    database: request.database,
                });
            } else {
                self.needs_login = true;
                self.state = QueueState::NeedsLogin;
            }
        } else if !has_next
            && self.in_flight.is_none()
            && matches!(self.state, QueueState::Fetching { .. })
        {
            self.state = QueueState::Idle;
        }
        poll
    }

    /// The answer to a fetch from `poll` (None: no answer, e.g. offline or a timeout).
    pub fn on_response(
        &mut self,
        fetch: &Fetch,
        response: Option<&HttpResponse>,
        now: Millis,
    ) -> Outcome {
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
        match response.map(|r| (r.status, r)) {
            Some((200, r)) => {
                paced = true;
                self.pending.remove(&k);
                if let Some(stats) = decode_stats(&r.body, &fetch.epd) {
                    outcome.stats = Some((fetch.database.clone(), fetch.epd.clone(), stats));
                }
            }
            Some((401, _)) => {
                outcome.unauthorized = true;
                self.needs_login = true;
                self.state = QueueState::NeedsLogin;
            }
            Some((429, r)) => {
                self.interval = (self.interval * 3 / 2).min(MAX_INTERVAL_MS);
                let until = now + r.retry_after_secs().map_or(DEFAULT_BAN_MS, |s| s * 1000);
                if self.banned_until.is_none_or(|b| until > b) {
                    self.banned_until = Some(until);
                    outcome.banned_until = Some(until);
                }
                self.state = QueueState::RateLimited { until };
                // Tried again after the pause.
                finished = false;
            }
            None => {
                self.state = QueueState::Offline;
                if coverage_start.is_some() {
                    self.offline_until = Some(now + OFFLINE_RETRY_MS);
                }
            }
            Some(_) => {
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

    const TOKEN: Option<&str> = Some("lio_x");

    fn ok(body: &str) -> HttpResponse {
        HttpResponse::new(200, body)
    }

    const STATS: &str = r#"{"white":10,"draws":5,"black":5,"moves":[{"uci":"e7e5","san":"e5","white":5,"draws":2,"black":3,"averageRating":1900}],"topGames":[],"opening":{"eco":"B00","name":"King's Pawn"}}"#;

    #[test]
    fn decoding_clamps_counts() {
        let body = r#"{"white":-10,"draws":5,"black":9223372036854775807,"moves":[{"uci":"e7e5","san":"e5","white":-5,"draws":2,"black":9223372036854775807}]}"#;
        let stats = decode_stats(body.as_bytes(), &epd("e4")).unwrap();
        assert_eq!((stats.white, stats.draws, stats.black), (0, 5, 1 << 40));
        assert_eq!(stats.moves[0].games(), 2 + (1 << 40));
        assert!(
            decode_stats(
                br#"{"white":1e30,"draws":0,"black":0,"moves":[]}"#,
                &epd("e4")
            )
            .is_none()
        );
    }

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
    fn requests_carry_the_token() {
        let r = explorer_request(&epd("e4"), &db(), "lio_x");
        assert_eq!(r.url, explorer_url(&epd("e4"), &db()));
        assert_eq!(
            (r.headers[0].name.as_str(), r.headers[0].value.as_str()),
            ("Authorization", "Bearer lio_x")
        );
        assert_eq!(r.timeout_secs, Some(20));
    }

    #[test]
    fn drops_requests_a_table_answers() {
        let mut q = ExplorerQueue::new(None, None);
        q.request(epd("e4"), db(), 1.0, false);
        q.request(epd("d4"), db(), 0.5, false);
        q.request(epd("e4"), ExplorerDatabase::masters(), 0.5, false);
        q.drop_answered(&db(), |e| *e == epd("e4"));
        assert_eq!(q.remaining(), 2);
    }

    #[test]
    fn nothing_is_fetched_for_a_database_whose_table_is_downloading() {
        let mut q = ExplorerQueue::new(None, None);
        q.hold(&db());
        q.focus(epd("e4"), db(), false, 0);
        q.request(epd("d4"), db(), 1.0, false);
        q.request(epd("c4"), db(), 0.8, false);
        q.request(epd("e4"), ExplorerDatabase::masters(), 0.5, false);
        // Only the other database's request goes out.
        let p = q.poll(1_000, TOKEN);
        assert_eq!(p.fetches.len(), 1);
        assert_eq!(p.fetches[0].database, ExplorerDatabase::masters());
        q.on_response(&p.fetches[0], Some(&ok(STATS)), 1_100);
        assert!(q.poll(5_000, TOKEN).fetches.is_empty());
        // The table answers the focus and d4; c4 is fetched once it is in.
        q.drop_answered(&db(), |e| *e == epd("e4") || *e == epd("d4"));
        q.release(&db());
        let p = q.poll(6_000, TOKEN);
        assert_eq!(p.fetches.len(), 1);
        assert_eq!(
            (p.fetches[0].lane, &p.fetches[0].epd),
            (Lane::Coverage, &epd("c4"))
        );
    }

    #[test]
    fn focus_waits_300_ms_and_the_next_focus_replaces_it() {
        let mut q = ExplorerQueue::new(None, None);
        q.focus(epd("e4"), db(), false, 0);
        let p = q.poll(0, TOKEN);
        assert!(p.fetches.is_empty());
        assert_eq!(p.wake_at, Some(300));
        q.focus(epd("d4"), db(), false, 100);
        let p = q.poll(400, TOKEN);
        assert_eq!(p.fetches.len(), 1);
        assert_eq!(p.fetches[0].epd, epd("d4"));
        let out = q.on_response(&p.fetches[0], Some(&ok(STATS)), 450);
        let (_, e, stats) = out.stats.unwrap();
        assert_eq!(e, epd("d4"));
        assert_eq!(stats.opening.unwrap().name, "King's Pawn");
        assert!(q.poll(500, TOKEN).fetches.is_empty());
        // Cached and fresh: nothing to do.
        q.focus(epd("c4"), db(), true, 600);
        assert_eq!(q.poll(1000, TOKEN), Poll::default());
    }

    #[test]
    fn coverage_queue_is_deduplicated_prioritized_and_paced() {
        let mut q = ExplorerQueue::new(None, None);
        q.request(epd("e4"), db(), 0.2, false);
        q.request(epd("d4"), db(), 0.5, false);
        q.request(epd("e4"), db(), 0.7, false);
        assert_eq!(q.remaining(), 2);
        let p = q.poll(1_000, TOKEN);
        assert_eq!(p.fetches[0].epd, epd("e4"));
        // One at a time.
        assert!(q.poll(1_100, TOKEN).fetches.is_empty());
        q.on_response(&p.fetches[0], Some(&ok(STATS)), 1_300);
        // The next one starts the interval after the previous start.
        let p = q.poll(1_500, TOKEN);
        assert!(p.fetches.is_empty());
        assert_eq!(p.wake_at, Some(1_000 + BASE_INTERVAL_MS));
        let p = q.poll(2_200, TOKEN);
        assert_eq!(p.fetches[0].epd, epd("d4"));
        q.on_response(&p.fetches[0], Some(&ok(STATS)), 2_300);
        assert_eq!(q.remaining(), 0);
        q.poll(5_000, TOKEN);
        assert_eq!(q.state(), &QueueState::Idle);
    }

    #[test]
    fn a_429_pauses_both_lanes_slows_down_and_retries() {
        let mut q = ExplorerQueue::new(None, None);
        q.request(epd("e4"), db(), 1.0, false);
        let p = q.poll(0, TOKEN);
        let out = q.on_response(
            &p.fetches[0],
            Some(&HttpResponse {
                status: 429,
                headers: vec![crate::http::Header {
                    name: "Retry-After".into(),
                    value: "90".into(),
                }],
                body: vec![],
            }),
            10,
        );
        assert_eq!(out.banned_until, Some(90_010));
        assert_eq!(q.interval_ms(), BASE_INTERVAL_MS * 3 / 2);
        q.focus(epd("d4"), db(), false, 20);
        let p = q.poll(1_000, TOKEN);
        assert!(p.fetches.is_empty());
        assert_eq!(p.wake_at, Some(90_010));
        assert_eq!(q.state(), &QueueState::RateLimited { until: 90_010 });
        let p = q.poll(90_010, TOKEN);
        assert_eq!(p.fetches.len(), 2); // the focus and the retried request
        // A ban persisted from an earlier launch holds too.
        let mut q = ExplorerQueue::new(Some(5_000), None);
        q.request(epd("e4"), db(), 1.0, false);
        assert_eq!(q.poll(0, TOKEN).wake_at, Some(5_000));
    }

    #[test]
    fn unauthorized_and_offline() {
        let mut q = ExplorerQueue::new(None, None);
        q.request(epd("e4"), db(), 1.0, false);
        // No token: the coverage check waits for a login.
        assert!(q.poll(0, None).fetches.is_empty());
        assert_eq!(q.state(), &QueueState::NeedsLogin);
        assert!(q.poll(10, TOKEN).fetches.is_empty());
        q.resume();
        let p = q.poll(20, TOKEN);
        let out = q.on_response(&p.fetches[0], Some(&HttpResponse::new(401, Vec::new())), 30);
        assert!(out.unauthorized);
        assert_eq!(q.state(), &QueueState::NeedsLogin);
        q.resume();
        let p = q.poll(40, TOKEN);
        q.on_response(&p.fetches[0], None, 50);
        assert_eq!(q.state(), &QueueState::Offline);
        let p = q.poll(60, TOKEN);
        assert!(p.fetches.is_empty());
        assert_eq!(p.wake_at, Some(50 + 30_000));
        assert_eq!(q.poll(30_050, TOKEN).fetches.len(), 1);
    }
}
