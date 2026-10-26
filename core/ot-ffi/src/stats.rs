//! Statistics (Anki's graphs) and files read without opening a repertoire.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use ot_core::chess::{Epd, Side};
use ot_core::explorer::ExplorerDatabase;
use ot_core::formats::{Sidecar, Summary, Timestamp, revlog};
use ot_core::http::{HttpRequest, HttpResponse};
use ot_core::repertoire::RepertoireTree;
use ot_core::statistics::{
    CardCounts, CardInfo, FutureDueSummary, GraphParts, GraphRange, GraphsContext, Hour,
    RetentionPeriod, ReviewsSummary, StageCounts, Streak, Today, TrueRetention, WeakMove,
};
use ot_core::training::anki::{Card, Counts, DeckConfig, RevlogEntry, SchedTiming};
use ot_core::training::{PracticeMode, Progress};

use crate::types::{ButtonCounts, FutureDue, Retrievability, Reviews};

#[derive(uniffi::Record)]
pub struct RetentionRow {
    pub period: RetentionPeriod,
    pub retention: TrueRetention,
}

/// The cards and review log statistics are computed from.
#[derive(uniffi::Object)]
pub struct Graphs(GraphsContext);

#[uniffi::export]
impl Graphs {
    #[uniffi::constructor]
    pub fn new(
        cards: Vec<Card>,
        new_count: i64,
        suspended_new_count: i64,
        revlog: Vec<RevlogEntry>,
        timing: SchedTiming,
        local_offset_secs: i64,
    ) -> Arc<Graphs> {
        Arc::new(Graphs(GraphsContext::new(
            cards,
            new_count,
            suspended_new_count,
            revlog,
            timing,
            local_offset_secs,
        )))
    }

    /// Statistics over the parts of one or more repertoires.
    #[uniffi::constructor]
    pub fn from_parts(
        parts: Vec<GraphParts>,
        timing: SchedTiming,
        local_offset_secs: i64,
    ) -> Arc<Graphs> {
        Arc::new(Graphs(GraphsContext::from_parts(
            parts,
            timing,
            local_offset_secs,
        )))
    }

    pub fn today(&self) -> Today {
        self.0.today()
    }

    pub fn card_counts(&self) -> CardCounts {
        self.0.card_counts()
    }

    pub fn future_due(&self) -> FutureDue {
        let f = self.0.future_due();
        FutureDue {
            due_by_day: f.due_by_day.into_iter().collect(),
            have_backlog: f.have_backlog,
            daily_load: f.daily_load,
        }
    }

    pub fn reviews(&self) -> Reviews {
        let r = self.0.reviews();
        Reviews {
            count: r.count.into_iter().collect(),
            time: r.time.into_iter().collect(),
        }
    }

    /// Each day from the first answer: the moves in each stage at its end.
    pub fn stages_by_day(&self) -> Vec<StageCounts> {
        self.0.stages_by_day()
    }

    /// Day → moves answered for the first time that day.
    pub fn first_studied(&self) -> HashMap<i64, i64> {
        self.0.first_studied().into_iter().collect()
    }

    /// Days studied, answers and time over a range (the table under Anki's Reviews graph).
    pub fn reviews_summary(&self, range: GraphRange) -> ReviewsSummary {
        self.0.reviews_summary(range)
    }

    /// Moves due over a range from today (the table under Anki's Future Due graph).
    pub fn future_due_summary(&self, range: GraphRange) -> FutureDueSummary {
        self.0.future_due_summary(range)
    }

    pub fn hours(&self, range: GraphRange) -> Vec<Hour> {
        self.0.hours(range).to_vec()
    }

    pub fn buttons(&self, range: GraphRange) -> ButtonCounts {
        let b = self.0.buttons(range);
        ButtonCounts {
            learning: b.learning.to_vec(),
            young: b.young.to_vec(),
            mature: b.mature.to_vec(),
        }
    }

    pub fn intervals(&self) -> HashMap<i64, i64> {
        self.0.intervals().into_iter().collect()
    }

    pub fn stability(&self) -> HashMap<i64, i64> {
        self.0.stability().into_iter().collect()
    }

    pub fn difficulty(&self) -> HashMap<i64, i64> {
        self.0.difficulty().into_iter().collect()
    }

    pub fn retrievability(&self) -> Retrievability {
        let r = self.0.retrievability();
        Retrievability {
            bins: r.bins.into_iter().collect(),
            average: r.average,
            sum: r.sum,
        }
    }

    /// True retention, of the cards in `positions` if given.
    pub fn true_retention(&self, positions: Option<Vec<Epd>>) -> Vec<RetentionRow> {
        let set: Option<HashSet<Epd>> = positions.map(|p| p.into_iter().collect());
        let filter = set.as_ref().map(|s| move |e: &Epd| s.contains(e));
        let result = match &filter {
            Some(f) => self.0.true_retention(Some(f)),
            None => self.0.true_retention(None),
        };
        result
            .into_iter()
            .map(|(period, retention)| RetentionRow { period, retention })
            .collect()
    }

    pub fn card_info(&self, card: Card, epd: Epd) -> CardInfo {
        self.0.card_info(&card, &epd)
    }

    pub fn streak(&self) -> Streak {
        self.0.streak()
    }
}

/// Expected recall in games: Σ reach × R over your card positions, divided by Σ reach.
#[uniffi::export]
pub fn expected_recall(
    cards: HashMap<Epd, Card>,
    reach: HashMap<Epd, f64>,
    now_secs: f64,
) -> Option<f64> {
    ot_core::statistics::expected_recall(&cards, &reach, now_secs)
}

/// Moves you forget most: leeches and most lapses first, then lowest recall.
#[uniffi::export]
pub fn weakest_moves(cards: HashMap<Epd, Card>, now_secs: f64, limit: u32) -> Vec<WeakMove> {
    ot_core::statistics::weakest_moves(&cards, now_secs, limit as usize)
}

/// A sidecar read without opening its PGN, for library rows.
#[derive(uniffi::Object)]
pub struct LibrarySidecar(Sidecar);

/// Reads a sidecar for a library row; None when it is not a sidecar.
#[uniffi::export]
pub fn library_sidecar(data: Vec<u8>) -> Option<Arc<LibrarySidecar>> {
    Sidecar::decode(&data)
        .ok()
        .map(|s| Arc::new(LibrarySidecar(s)))
}

#[uniffi::export]
impl LibrarySidecar {
    pub fn id(&self) -> String {
        self.0.id.clone()
    }

    pub fn color(&self) -> Side {
        self.0.color
    }

    pub fn database(&self) -> ExplorerDatabase {
        self.0.database.clone()
    }

    pub fn target_games(&self) -> i64 {
        self.0.target_games
    }

    pub fn practice_mode(&self) -> Option<PracticeMode> {
        self.0.practice_mode
    }

    pub fn summary(&self) -> Option<Summary> {
        self.0.summary.clone()
    }

    pub fn config_key(&self) -> String {
        self.0.config_key()
    }

    pub fn cards(&self) -> HashMap<Epd, Card> {
        self.0.cards()
    }

    /// This repertoire's part of the whole collection's statistics, estimated without its
    /// PGN; `revlog` is its review log file.
    pub fn graph_parts(&self, revlog: Vec<u8>) -> GraphParts {
        GraphParts::collection_estimate(&self.0, revlog::decode(&revlog))
    }

    pub fn estimated_progress(&self) -> Progress {
        self.0.estimated_progress()
    }

    pub fn estimated_study_counts(
        &self,
        new_per_day: i64,
        reviews_per_day: i64,
        timing: SchedTiming,
    ) -> Counts {
        let config = DeckConfig {
            new_per_day,
            reviews_per_day,
            ..DeckConfig::default()
        };
        self.0.estimated_study_counts(&config, &timing)
    }

    pub fn next_due(&self, timing: SchedTiming) -> Option<i64> {
        self.0.next_due(&timing)
    }

    pub fn later_learning_dues(&self, timing: SchedTiming) -> Vec<i64> {
        self.0.later_learning_dues(&timing)
    }

    pub fn due_tomorrow(&self, timing: SchedTiming) -> i64 {
        self.0.due_tomorrow(&timing)
    }
}

/// The sidecar of a new repertoire.
#[uniffi::export]
pub fn new_sidecar(
    id: String,
    color: Side,
    database: ExplorerDatabase,
    target_games: i64,
    now: Timestamp,
) -> Vec<u8> {
    let mut s = Sidecar::new(id, color, now);
    s.database = database;
    s.target_games = target_games;
    s.encoded()
}

/// A new, empty repertoire PGN whose game is named `name`.
#[uniffi::export]
pub fn new_repertoire_pgn(name: String) -> String {
    let mut tree = RepertoireTree::default();
    tree.set_tag("Event", &name);
    tree.pgn_text()
}

/// Review log entries from a `.otlog.jsonl` file, in id order (bad lines skipped).
#[uniffi::export]
pub fn decode_revlog(data: Vec<u8>) -> Vec<RevlogEntry> {
    revlog::decode(&data)
}

#[uniffi::export]
pub fn merge_revlogs(a: Vec<RevlogEntry>, b: Vec<RevlogEntry>) -> Vec<RevlogEntry> {
    revlog::merged(&a, &b)
}

/// Two copies of a review log file (iCloud conflict versions) as one file: union by id.
#[uniffi::export]
pub fn merge_revlog_data(a: Vec<u8>, b: Vec<u8>) -> Vec<u8> {
    revlog::encode(&revlog::merged(&revlog::decode(&a), &revlog::decode(&b)))
}

/// Two copies of a sidecar file (iCloud conflict versions) as one file: cards by latest
/// review, settings by latest change. An unreadable copy is dropped; None when neither reads.
#[uniffi::export]
pub fn merge_sidecar_data(a: Vec<u8>, b: Vec<u8>) -> Option<Vec<u8>> {
    match (Sidecar::decode(&a), Sidecar::decode(&b)) {
        (Ok(a), Ok(b)) => Some(a.merged(&b).encoded()),
        (Ok(s), Err(_)) | (Err(_), Ok(s)) => Some(s.encoded()),
        (Err(_), Err(_)) => None,
    }
}

#[uniffi::export]
pub fn sidecar_extension() -> String {
    ot_core::formats::SIDECAR_EXTENSION.to_owned()
}

#[uniffi::export]
pub fn revlog_extension() -> String {
    revlog::FILE_EXTENSION.to_owned()
}

// Lichess sign-in

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SignInError {
    #[error("{message}")]
    Failed { message: String },
}

impl From<ot_core::lichess::AuthError> for SignInError {
    fn from(e: ot_core::lichess::AuthError) -> SignInError {
        SignInError::Failed {
            message: e.to_string(),
        }
    }
}

#[derive(uniffi::Record)]
pub struct Token {
    pub token: String,
    /// Unix seconds.
    pub expires_at: i64,
}

#[uniffi::export]
pub fn lichess_random_string(random: Vec<u8>) -> String {
    ot_core::lichess::random_string(&random)
}

#[uniffi::export]
pub fn lichess_authorize_url(verifier: String, state: String) -> String {
    ot_core::lichess::authorize_url(&verifier, &state)
}

#[uniffi::export]
pub fn lichess_callback_scheme() -> String {
    ot_core::lichess::CALLBACK_SCHEME.to_owned()
}

/// The code from the redirect, or None when the user declined.
#[uniffi::export]
pub fn lichess_parse_callback(
    url: String,
    expected_state: String,
) -> Result<Option<String>, SignInError> {
    Ok(ot_core::lichess::parse_callback(&url, &expected_state)?)
}

/// Exchanges the code from the callback for a token.
#[uniffi::export]
pub fn lichess_token_request(code: String, verifier: String) -> HttpRequest {
    ot_core::lichess::token_request(&code, &verifier)
}

#[uniffi::export]
pub fn lichess_parse_token(response: HttpResponse, now_secs: i64) -> Result<Token, SignInError> {
    let (token, expires_at) = ot_core::lichess::parse_token_response(&response, now_secs)?;
    Ok(Token { token, expires_at })
}

/// Signing out: revokes the token.
#[uniffi::export]
pub fn lichess_revoke_request(token: String) -> HttpRequest {
    ot_core::lichess::revoke_request(&token)
}

#[uniffi::export]
pub fn lichess_account_request(token: String) -> HttpRequest {
    ot_core::lichess::account_request(&token)
}

/// The username from the account request's answer.
#[uniffi::export]
pub fn lichess_parse_account(response: HttpResponse) -> Option<String> {
    ot_core::lichess::parse_account(&response)
}
