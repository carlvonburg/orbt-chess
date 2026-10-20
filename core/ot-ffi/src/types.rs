//! The core's plain types, exposed as they are (UniFFI remote types) or, where a core type
//! holds something the bindings cannot express, as a record built from it.

use std::collections::HashMap;

use ot_core::builder::{Arrow, ArrowStyle};
use ot_core::chess::{BoardPiece, BoardSquare, Epd, PieceKind, PlayedMove, Side};
use ot_core::coverage::{CoverageGap, GapKind, NodeCoverage, ReplyInfo, Status};
use ot_core::document::{Changes, OutlineItem, StudyDefaults};
use ot_core::drill::{DrillMode, Feedback, Phase};
use ot_core::explorer::queue::{Lane, QueueState};
use ot_core::explorer::{
    ExplorerDatabase, ExplorerMove, ExplorerSpeed, ExplorerStats, OpeningName,
};
use ot_core::formats::{Summary, Timestamp};
use ot_core::http::{Header, HttpMethod, HttpRequest, HttpResponse};
use ot_core::lichess::cloud_eval::{CloudEval, CloudEvalLookup, Pv};
use ot_core::repertoire::{NodeId, RepertoireNode, RepertoireTree};
use ot_core::statistics::{
    CardCounts, CardInfo, GraphParts, GraphRange, Hour, RetentionPeriod, ReviewCounts, Streak,
    Today, TrueRetention, WeakMove,
};
use ot_core::training::anki::{
    Card, CardQueue, CardType, Counts, DayLimit, DeckLimits, DeckStudyStats, MemoryState,
    QueueKind, Rating, RemainingLimits, RevlogEntry, RevlogReviewKind, SchedTiming,
};
use ot_core::training::{AnswerKind, LineOutcome, MoveRole, PracticeMode, Progress, StudyLine};

// Custom types

uniffi::custom_type!(Epd, String, {
    remote,
    lower: |epd| epd.as_str().to_owned(),
    try_lift: |text| Ok(Epd::new(text)),
});

/// A square, 0...63 with a1 = 0, h8 = 63.
#[uniffi::remote(Record)]
pub struct BoardSquare {
    pub index: u8,
}

uniffi::custom_type!(Timestamp, i64, {
    remote,
    lower: |t| t.0,
    try_lift: |millis| Ok(Timestamp(millis)),
});

// Chess

#[uniffi::remote(Enum)]
pub enum Side {
    White,
    Black,
}

#[uniffi::remote(Enum)]
pub enum PieceKind {
    Pawn,
    Knight,
    Bishop,
    Rook,
    Queen,
    King,
}

#[uniffi::remote(Record)]
pub struct PlayedMove {
    pub san: String,
    pub uci: String,
}

#[uniffi::remote(Record)]
pub struct BoardPiece {
    pub side: Side,
    pub kind: PieceKind,
    pub square: BoardSquare,
}

// Explorer

#[uniffi::remote(Enum)]
pub enum ExplorerSpeed {
    UltraBullet,
    Bullet,
    Blitz,
    Rapid,
    Classical,
    Correspondence,
}

// HTTP

#[uniffi::remote(Enum)]
pub enum HttpMethod {
    Get,
    Post,
    Delete,
}

#[uniffi::remote(Record)]
pub struct Header {
    pub name: String,
    pub value: String,
}

#[uniffi::remote(Record)]
pub struct HttpRequest {
    pub method: HttpMethod,
    pub url: String,
    pub headers: Vec<Header>,
    pub body: Vec<u8>,
    pub timeout_secs: Option<u32>,
}

#[uniffi::remote(Record)]
pub struct HttpResponse {
    pub status: u16,
    pub headers: Vec<Header>,
    pub body: Vec<u8>,
}

// Lichess cloud evals

#[uniffi::remote(Record)]
pub struct Pv {
    pub moves: String,
    pub cp: Option<i32>,
    pub mate: Option<i32>,
}

#[uniffi::remote(Record)]
pub struct CloudEval {
    pub depth: u32,
    pub pvs: Vec<Pv>,
}

#[uniffi::remote(Enum)]
pub enum CloudEvalLookup {
    Cached(Option<CloudEval>),
    Fetch(HttpRequest),
}

/// The eval after `uci` ("+0.3", "#-2"), if it starts one of the cloud lines.
#[uniffi::export]
pub fn cloud_eval_text(eval: CloudEval, uci: String) -> Option<String> {
    eval.text_for(&uci)
}

// Explorer

#[uniffi::remote(Enum)]
pub enum ExplorerDatabase {
    Masters {},
    Lichess {
        ratings: Vec<i64>,
        speeds: Vec<ExplorerSpeed>,
    },
}

#[uniffi::remote(Record)]
pub struct ExplorerMove {
    pub uci: String,
    pub san: String,
    pub white: i64,
    pub draws: i64,
    pub black: i64,
    pub average_rating: Option<i64>,
}

#[uniffi::remote(Record)]
pub struct OpeningName {
    pub eco: String,
    pub name: String,
}

#[uniffi::remote(Record)]
pub struct ExplorerStats {
    pub white: i64,
    pub draws: i64,
    pub black: i64,
    pub moves: Vec<ExplorerMove>,
    pub opening: Option<OpeningName>,
}

#[uniffi::remote(Enum)]
pub enum Lane {
    Focus,
    Coverage,
}

#[uniffi::remote(Enum)]
pub enum QueueState {
    Idle,
    Fetching { remaining: u64 },
    RateLimited { until: i64 },
    NeedsLogin,
    Offline,
}

// Coverage

#[uniffi::remote(Enum)]
pub enum GapKind {
    MissingMove,
    MissingReply { uci: String, san: String },
}

#[uniffi::remote(Record)]
pub struct CoverageGap {
    pub node: NodeId,
    pub kind: GapKind,
    pub mass: f64,
}

#[uniffi::remote(Record)]
pub struct ReplyInfo {
    pub uci: String,
    pub san: String,
    pub share: f64,
    pub reach: f64,
    pub required: bool,
    pub excluded: bool,
    pub child: Option<NodeId>,
    pub transposes_to: Option<NodeId>,
    pub completion: f64,
    pub games: i64,
}

#[uniffi::remote(Enum)]
pub enum Status {
    Required,
    BelowTarget,
    Pending,
    Unknown,
    Gap,
    Transposition(NodeId),
    Alternative,
}

#[uniffi::remote(Record)]
pub struct NodeCoverage {
    pub reach: Option<f64>,
    pub status: Status,
    pub completion: f64,
    pub gap_count: i64,
    pub gap_mass: f64,
    pub pending_count: i64,
    pub biggest_gap: Option<CoverageGap>,
    pub local_gaps: Vec<CoverageGap>,
    pub replies: Vec<ReplyInfo>,
    pub counts: bool,
}

// Training

#[uniffi::remote(Enum)]
pub enum CardType {
    New,
    Learn,
    Review,
    Relearn,
}

#[uniffi::remote(Enum)]
pub enum CardQueue {
    Suspended,
    New,
    Learn,
    Review,
    DayLearn,
}

#[uniffi::remote(Enum)]
pub enum Rating {
    Again,
    Hard,
    Good,
    Easy,
}

#[uniffi::remote(Enum)]
pub enum RevlogReviewKind {
    Learning,
    Review,
    Relearning,
    Filtered,
    Manual,
    Rescheduled,
}

#[uniffi::remote(Record)]
pub struct MemoryState {
    pub difficulty: f64,
    pub stability: f64,
}

#[uniffi::remote(Record)]
pub struct Card {
    pub added: i64,
    pub ctype: CardType,
    pub due: i64,
    pub ease_factor: i64,
    pub id: i64,
    pub interval: i64,
    pub lapses: i64,
    pub last_review_time: Option<i64>,
    pub leech: Option<bool>,
    pub memory: Option<MemoryState>,
    pub original_position: Option<i64>,
    pub queue: CardQueue,
    pub remaining_steps: i64,
    pub reps: i64,
}

#[uniffi::remote(Record)]
pub struct RevlogEntry {
    pub cid: Epd,
    pub ease: i64,
    pub factor: i64,
    pub id: i64,
    pub ivl: i64,
    pub last_ivl: i64,
    pub time: i64,
    pub kind: RevlogReviewKind,
}

#[uniffi::remote(Record)]
pub struct SchedTiming {
    pub days_elapsed: i64,
    pub next_day_at: i64,
    pub now: i64,
}

#[uniffi::remote(Record)]
pub struct DayLimit {
    pub limit: i64,
    pub today: i64,
}

#[uniffi::remote(Record)]
pub struct DeckLimits {
    pub new_limit: Option<i64>,
    pub new_limit_today: Option<DayLimit>,
    pub review_limit: Option<i64>,
    pub review_limit_today: Option<DayLimit>,
}

#[uniffi::remote(Record)]
pub struct DeckStudyStats {
    pub last_day_studied: i64,
    pub milliseconds_studied: i64,
    pub new_studied: i64,
    pub review_studied: i64,
}

#[uniffi::remote(Record)]
pub struct RemainingLimits {
    pub review: i64,
    pub new: i64,
    pub cap_new_to_review: bool,
}

#[uniffi::remote(Record)]
pub struct Counts {
    pub new: i64,
    pub learning: i64,
    pub review: i64,
}

#[uniffi::remote(Enum)]
pub enum QueueKind {
    New,
    Learning,
    Review,
}

#[uniffi::remote(Record)]
pub struct Progress {
    pub cards: i64,
    pub learning: i64,
    pub young: i64,
    pub mature: i64,
    pub suspended: i64,
}

#[uniffi::remote(Enum)]
pub enum PracticeMode {
    IndividualMoves,
    CompleteLinesEveryTime,
    CompleteLinesOncePerSession,
}

#[uniffi::remote(Enum)]
pub enum AnswerKind {
    Queued,
    Introduce,
    ReviewAhead,
}

#[uniffi::remote(Enum)]
pub enum MoveRole {
    Auto,
    Practice,
    Answer(AnswerKind),
}

#[uniffi::remote(Enum)]
pub enum LineOutcome {
    Correct,
    Alternative,
    Wrong { expected: PlayedMove },
}

#[uniffi::remote(Record)]
pub struct StudyDefaults {
    pub new_per_day: i64,
    pub reviews_per_day: i64,
    pub practice_mode: PracticeMode,
}

#[uniffi::remote(Record)]
pub struct Changes {
    pub revision: u64,
    pub tree_changed: bool,
    pub save_pgn_after_ms: Option<u32>,
    pub save_sidecar_after_ms: Option<u32>,
    pub reload_stats: bool,
    pub coverage_check: bool,
}

#[uniffi::remote(Record)]
pub struct OutlineItem {
    pub id: NodeId,
    pub first: NodeId,
    pub text: String,
    pub has_children: bool,
}

#[uniffi::remote(Record)]
pub struct Summary {
    pub card_count: i64,
    pub completion: f64,
    pub config_key: String,
    pub due_count: i64,
    pub gap_count: i64,
    pub mature_count: i64,
    pub saved_move_count: Option<i64>,
    pub suspended_count: Option<i64>,
}

// Builder and drill

#[uniffi::remote(Enum)]
pub enum ArrowStyle {
    Mine,
    Opponent,
    Gap,
    Hint,
}

#[uniffi::remote(Record)]
pub struct Arrow {
    pub from: BoardSquare,
    pub to: BoardSquare,
    pub style: ArrowStyle,
    pub width: f64,
    pub opacity: f64,
    pub dashed: bool,
}

#[uniffi::remote(Enum)]
pub enum DrillMode {
    Study,
    Branch(NodeId),
}

#[uniffi::remote(Enum)]
pub enum Feedback {
    None,
    Correct,
    Wrong { expected: PlayedMove },
    Alternative,
    NewMove(PlayedMove),
}

#[uniffi::remote(Enum)]
pub enum Phase {
    Idle,
    Rewinding,
    Autoplay,
    UserTurn,
    LineDone,
    Finished,
}

// Statistics

#[uniffi::remote(Enum)]
pub enum GraphRange {
    Month,
    ThreeMonths,
    Year,
    All,
}

#[uniffi::remote(Enum)]
pub enum RetentionPeriod {
    Today,
    Yesterday,
    Week,
    Month,
    Year,
    AllTime,
}

#[uniffi::remote(Record)]
pub struct Today {
    pub answer_count: i64,
    pub answer_millis: i64,
    pub correct_count: i64,
    pub mature_count: i64,
    pub mature_correct: i64,
    pub learn_count: i64,
    pub review_count: i64,
    pub relearn_count: i64,
    pub early_review_count: i64,
}

#[uniffi::remote(Record)]
pub struct CardCounts {
    pub new: i64,
    pub learn: i64,
    pub relearn: i64,
    pub young: i64,
    pub mature: i64,
    pub suspended: i64,
}

#[uniffi::remote(Record)]
pub struct ReviewCounts {
    pub learn: i64,
    pub relearn: i64,
    pub young: i64,
    pub mature: i64,
    pub filtered: i64,
}

#[uniffi::remote(Record)]
pub struct Hour {
    pub total: i64,
    pub correct: i64,
}

#[uniffi::remote(Record)]
pub struct TrueRetention {
    pub young_passed: i64,
    pub young_failed: i64,
    pub mature_passed: i64,
    pub mature_failed: i64,
}

#[uniffi::remote(Record)]
pub struct Streak {
    pub current: i64,
    pub longest: i64,
    pub studied_today: bool,
}

#[uniffi::remote(Record)]
pub struct WeakMove {
    pub epd: Epd,
    pub lapses: i64,
    pub retrievability: Option<f64>,
    pub leech: bool,
}

/// What one repertoire contributes to the statistics.
#[uniffi::remote(Record)]
pub struct GraphParts {
    pub cards: Vec<Card>,
    pub new_count: i64,
    pub suspended_new_count: i64,
    pub revlog: Vec<RevlogEntry>,
}

#[uniffi::remote(Record)]
pub struct CardInfo {
    pub added: i64,
    pub first_review: Option<i64>,
    pub latest_review: Option<i64>,
    pub due: Option<i64>,
    pub interval: i64,
    pub reps: i64,
    pub lapses: i64,
    pub average_millis: i64,
    pub total_millis: i64,
    pub retrievability: Option<f64>,
    pub memory: Option<MemoryState>,
    pub history: Vec<RevlogEntry>,
}

// Records built from core types

/// A node of the move tree (`RepertoireNode` without its cached position).
#[derive(uniffi::Record, Clone, Debug)]
pub struct Node {
    pub id: NodeId,
    pub parent: Option<NodeId>,
    /// The move that leads here; None for the root.
    pub mv: Option<PlayedMove>,
    pub fen: String,
    pub epd: Epd,
    pub ply: u32,
    /// `children[0]` is the main continuation.
    pub children: Vec<NodeId>,
    pub comments: Vec<String>,
    pub pre_comments: Vec<String>,
    pub nags: Vec<i32>,
    /// The note without embedded commands like `[%cal Ge2e4]`.
    pub note: String,
    pub side_to_move: Side,
    /// For a node without moves: where its lines are stored.
    pub transposition_target: Option<NodeId>,
}

impl Node {
    pub fn from_core(n: &RepertoireNode, tree: &RepertoireTree) -> Node {
        Node {
            id: n.id,
            parent: n.parent,
            mv: n.mv.clone(),
            fen: n.fen(),
            epd: n.epd.clone(),
            ply: n.ply,
            children: n.children.clone(),
            comments: n.comments.clone(),
            pre_comments: n.pre_comments.clone(),
            nags: n.nags.clone(),
            note: n.note(),
            side_to_move: n.side_to_move(),
            transposition_target: tree.transposition_target(n.id),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct StudyLineRecord {
    pub nodes: Vec<NodeId>,
    /// Index into `nodes` → the role of your move from there.
    pub roles: HashMap<u32, MoveRole>,
    pub target: Epd,
}

impl From<&StudyLine> for StudyLineRecord {
    fn from(l: &StudyLine) -> StudyLineRecord {
        StudyLineRecord {
            nodes: l.nodes.clone(),
            roles: l.roles.iter().map(|(&i, &r)| (i as u32, r)).collect(),
            target: l.target.clone(),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct FutureDue {
    /// Days from today (0 = today, negative = overdue) → cards.
    pub due_by_day: HashMap<i64, i64>,
    pub have_backlog: bool,
    pub daily_load: i64,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct Reviews {
    pub count: HashMap<i64, ReviewCounts>,
    pub time: HashMap<i64, ReviewCounts>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct ButtonCounts {
    /// Again ... Easy.
    pub learning: Vec<i64>,
    pub young: Vec<i64>,
    pub mature: Vec<i64>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct Retrievability {
    pub bins: HashMap<i64, i64>,
    pub average: f64,
    pub sum: f64,
}

// Small helpers on the exposed types, as free functions (UniFFI has no methods on records).

#[uniffi::export]
pub fn epd_side_to_move(epd: Epd) -> Side {
    epd.side_to_move()
}

#[uniffi::export]
pub fn epd_query_fen(epd: Epd) -> String {
    epd.query_fen()
}

#[uniffi::export]
pub fn square_from_notation(notation: String) -> Option<BoardSquare> {
    BoardSquare::parse(&notation)
}

#[uniffi::export]
pub fn square_notation(square: BoardSquare) -> String {
    square.to_string()
}

#[uniffi::export]
pub fn san_loose(san: String) -> String {
    ot_core::chess::san::loose(&san)
}

#[uniffi::export]
pub fn database_cache_key(database: ExplorerDatabase) -> String {
    database.cache_key()
}

#[uniffi::export]
pub fn database_summary(database: ExplorerDatabase) -> String {
    database.summary()
}

#[uniffi::export]
pub fn database_rating_buckets() -> Vec<i64> {
    ExplorerDatabase::RATING_BUCKETS.to_vec()
}

#[uniffi::export]
pub fn database_default_lichess() -> ExplorerDatabase {
    ExplorerDatabase::default_lichess()
}

#[uniffi::export]
pub fn explorer_speed_title(speed: ExplorerSpeed) -> String {
    speed.title().to_owned()
}

#[uniffi::export]
pub fn practice_mode_title(mode: PracticeMode) -> String {
    mode.title().to_owned()
}

#[uniffi::export]
pub fn range_title(range: GraphRange) -> String {
    range.title().to_owned()
}

/// Days a graph range covers; 0 for all time.
#[uniffi::export]
pub fn range_days(range: GraphRange) -> i64 {
    range.days()
}

#[uniffi::export]
pub fn retention_period_title(period: RetentionPeriod) -> String {
    period.title().to_owned()
}

#[uniffi::export]
pub fn retention_rate_young(r: TrueRetention) -> Option<f64> {
    r.young()
}

#[uniffi::export]
pub fn retention_rate_mature(r: TrueRetention) -> Option<f64> {
    r.mature()
}

#[uniffi::export]
pub fn retention_rate_total(r: TrueRetention) -> Option<f64> {
    r.total()
}

#[uniffi::export]
pub fn card_is_mature(card: Card) -> bool {
    card.is_mature()
}

#[uniffi::export]
pub fn card_retrievability(card: Card, now_secs: f64) -> Option<f64> {
    card.retrievability(now_secs)
}

#[uniffi::export]
pub fn gap_seen_every(gap: CoverageGap) -> i64 {
    gap.seen_every()
}

#[uniffi::export]
pub fn coverage_seen_every(coverage: NodeCoverage) -> Option<i64> {
    coverage.seen_every()
}

#[uniffi::export]
pub fn explorer_stats_share(stats: ExplorerStats, uci: String) -> f64 {
    stats.share(&uci)
}

#[uniffi::export]
pub fn explorer_move_score(mv: ExplorerMove, side: Side) -> f64 {
    mv.score(side)
}

#[uniffi::export]
pub fn default_study_defaults() -> StudyDefaults {
    StudyDefaults::default()
}

#[uniffi::export]
pub fn deck_limits_is_empty(limits: DeckLimits) -> bool {
    limits.is_empty()
}

/// "1. d4 d5 2. c4 c6", numbered from `start_ply` (0 = White's first move).
#[uniffi::export]
pub fn move_list(moves: Vec<PlayedMove>, start_ply: u32) -> String {
    ot_core::lichess::move_list(&moves, start_ply as usize)
}

/// The Lichess analysis board for a line.
#[uniffi::export]
pub fn lichess_analysis_url(moves: Vec<PlayedMove>, orientation: Side) -> String {
    ot_core::lichess::analysis_url(&moves, orientation)
}

/// Anki's preset values the settings screen shows.
#[derive(uniffi::Record)]
pub struct PresetInfo {
    pub new_per_day: i64,
    pub reviews_per_day: i64,
    /// Minutes.
    pub learn_steps: Vec<f64>,
    pub relearn_steps: Vec<f64>,
    pub desired_retention: f64,
    pub learn_ahead_secs: i64,
    pub rollover_hour: i64,
}

#[uniffi::export]
pub fn anki_preset() -> PresetInfo {
    let c = ot_core::training::anki::DeckConfig::default();
    PresetInfo {
        new_per_day: c.new_per_day,
        reviews_per_day: c.reviews_per_day,
        learn_steps: c.learn_steps,
        relearn_steps: c.relearn_steps,
        desired_retention: c.desired_retention,
        learn_ahead_secs: c.learn_ahead_secs,
        rollover_hour: SchedTiming::ROLLOVER_HOUR,
    }
}
