//! One engine and the position it analyses. The engine answers in order, so a search's output
//! ends with its `bestmove`: after a `stop`, everything up to that `bestmove` belongs to the
//! old position and is dropped. Options are only set while the engine is idle.
//!
//! The cloud eval comes first (lichess mobile's order): the local engine waits
//! `CLOUD_WAIT_MS` for it, never runs when it is `CLOUD_DEEP_ENOUGH`, and replaces it once it is
//! deeper.

use super::uci::{EngineCommand, EngineOutput, Score, parse_line};
use super::{
    CLOUD_DEEP_ENOUGH, CLOUD_WAIT_MS, EngineKind, EngineSettings, LOCAL_OVER_SHORT_CLOUD_DEPTH,
    MAX_LINE_MOVES, MAX_LINES,
};
use crate::chess::{ChessPosition, Epd, PlayedMove, Side};
use crate::lichess::cloud_eval::CloudEval;
use crate::lichess::move_list;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EvalSource {
    Cloud,
    Local,
}

/// A line to show: its evaluation from White's point of view and its moves.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PvLine {
    pub score: Score,
    /// "+0.3", "#-2".
    pub eval: String,
    pub moves: Vec<PlayedMove>,
    /// "2… Nc6 3. Bb5 Nf6".
    pub text: String,
}

/// What to show for the position being analysed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EngineLines {
    pub lines: Vec<PvLine>,
    pub depth: u32,
    pub source: Option<EvalSource>,
    /// The local engine is searching this position.
    pub searching: bool,
    /// Thousands of nodes per second of the local search.
    pub knps: Option<u64>,
}

impl EngineLines {
    /// The evaluation of the position: its best line's.
    pub fn eval(&self) -> Option<&str> {
        self.lines.first().map(|line| line.eval.as_str())
    }
}

/// What the platform does next: write these commands to the engine, and call `poll` at
/// `wake_at_ms` if nothing else happens before.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EngineStep {
    pub commands: Vec<EngineCommand>,
    pub wake_at_ms: Option<u64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Engine {
    NotStarted,
    /// `uci` sent, waiting for `uciok`.
    Handshake,
    Idle,
    /// Searching for the target with this id.
    Searching(u64),
    /// `stop` sent, waiting for `bestmove`.
    Stopping,
}

struct Target {
    id: u64,
    start_fen: String,
    moves: Vec<String>,
    position: ChessPosition,
    epd: Epd,
    settings: EngineSettings,
    legal_moves: usize,
    local_at_ms: u64,
    started: bool,
    finished: bool,
}

#[derive(Clone, Debug)]
struct LocalLine {
    /// White's point of view.
    score: Score,
    depth: u32,
    pv: Vec<String>,
}

pub struct EngineSearch {
    kind: EngineKind,
    engine: Engine,
    sent_options: Vec<EngineCommand>,
    target: Option<Target>,
    next_id: u64,
    cloud: Option<(Epd, CloudEval)>,
    /// The target's local lines by MultiPV index.
    local: Vec<Option<LocalLine>>,
    nps: Option<u64>,
}

impl EngineSearch {
    pub fn new(kind: EngineKind) -> EngineSearch {
        EngineSearch {
            kind,
            engine: Engine::NotStarted,
            sent_options: Vec::new(),
            target: None,
            next_id: 1,
            cloud: None,
            local: Vec::new(),
            nps: None,
        }
    }

    pub fn kind(&self) -> EngineKind {
        self.kind
    }

    /// The handshake, once the engine runs.
    pub fn start(&mut self) -> EngineStep {
        if self.engine != Engine::NotStarted {
            return EngineStep::default();
        }
        self.engine = Engine::Handshake;
        EngineStep {
            commands: vec![EngineCommand::Uci],
            wake_at_ms: None,
        }
    }

    /// Analyses the position after `moves` (UCI) from `start_fen`. Asking again for the same
    /// position and settings changes nothing; an illegal move stops the analysis.
    pub fn analyse(
        &mut self,
        start_fen: &str,
        moves: &[String],
        settings: &EngineSettings,
        now_ms: u64,
    ) -> EngineStep {
        let mut position = ChessPosition::from_fen(start_fen);
        for uci in moves {
            position = position.and_then(|p| p.play_uci(uci).map(|(_, next)| next));
        }
        let Some(position) = position else {
            return self.stop();
        };
        let epd = position.epd();
        if let Some(target) = &self.target
            && target.epd == epd
            && target.settings == *settings
        {
            return self.drive(now_ms);
        }
        let mut settings = settings.clone();
        settings.lines = settings.lines.clamp(1, MAX_LINES);
        let wait = if settings.cloud { CLOUD_WAIT_MS } else { 0 };
        self.target = Some(Target {
            id: self.next_id,
            start_fen: start_fen.to_owned(),
            moves: moves.to_vec(),
            legal_moves: position.legal_moves().len(),
            position,
            epd,
            settings,
            local_at_ms: now_ms.saturating_add(wait),
            started: false,
            finished: false,
        });
        self.next_id += 1;
        self.local.clear();
        self.nps = None;
        self.drive(now_ms)
    }

    /// The cloud eval of `epd` (None: Lichess has none or could not be reached).
    pub fn on_cloud(&mut self, epd: &Epd, eval: Option<CloudEval>, now_ms: u64) -> EngineStep {
        if let Some(eval) = eval {
            self.cloud = Some((epd.clone(), eval));
        }
        self.drive(now_ms)
    }

    /// The time `EngineStep::wake_at_ms` asked for has come.
    pub fn poll(&mut self, now_ms: u64) -> EngineStep {
        self.drive(now_ms)
    }

    /// Stops analysing.
    pub fn stop(&mut self) -> EngineStep {
        self.target = None;
        self.local.clear();
        let mut step = EngineStep::default();
        if let Engine::Searching(_) = self.engine {
            self.engine = Engine::Stopping;
            step.commands.push(EngineCommand::Stop);
        }
        step
    }

    /// A line the engine printed.
    pub fn on_line(&mut self, line: &str, now_ms: u64) -> EngineStep {
        match parse_line(line) {
            EngineOutput::UciOk if self.engine == Engine::Handshake => {
                self.engine = Engine::Idle;
            }
            EngineOutput::BestMove(_) => match self.engine {
                Engine::Searching(id) => {
                    self.engine = Engine::Idle;
                    if let Some(target) = &mut self.target
                        && target.id == id
                    {
                        target.finished = true;
                    }
                }
                Engine::Stopping => self.engine = Engine::Idle,
                _ => {}
            },
            EngineOutput::Info(info) => {
                let Engine::Searching(id) = self.engine else {
                    return EngineStep::default();
                };
                let Some(target) = &self.target else {
                    return EngineStep::default();
                };
                if target.id != id || info.bound.is_some() {
                    return EngineStep::default();
                }
                let index = (info.multipv - 1) as usize;
                if let (Some(depth), Some(score)) = (info.depth, info.score)
                    && !info.pv.is_empty()
                    && index < target.settings.lines as usize
                {
                    let score = match target.position.side_to_move() {
                        Side::White => score,
                        Side::Black => score.negated(),
                    };
                    if self.local.len() <= index {
                        self.local.resize(index + 1, None);
                    }
                    self.local[index] = Some(LocalLine {
                        score,
                        depth,
                        pv: info.pv,
                    });
                }
                if info.nps.is_some() {
                    self.nps = info.nps;
                }
                return EngineStep::default();
            }
            _ => return EngineStep::default(),
        }
        self.drive(now_ms)
    }

    /// Starts, stops or waits, depending on the engine and the target.
    fn drive(&mut self, now_ms: u64) -> EngineStep {
        let mut step = EngineStep::default();
        let deep_cloud = self
            .target
            .as_ref()
            .is_some_and(|t| self.cloud_is_enough(t));
        let Some(target) = &mut self.target else {
            return step;
        };
        if target.legal_moves == 0 || deep_cloud {
            target.finished = true;
        }
        match self.engine {
            Engine::Searching(id) if id != target.id || target.finished => {
                self.engine = Engine::Stopping;
                step.commands.push(EngineCommand::Stop);
            }
            Engine::Idle if !target.started && !target.finished => {
                if target.local_at_ms > now_ms {
                    step.wake_at_ms = Some(target.local_at_ms);
                } else {
                    let options = self.kind.options(&target.settings);
                    step.commands.extend(
                        options
                            .iter()
                            .filter(|option| !self.sent_options.contains(option))
                            .cloned(),
                    );
                    self.sent_options = options;
                    step.commands.push(EngineCommand::Position {
                        fen: target.start_fen.clone(),
                        moves: target.moves.clone(),
                    });
                    let ms = target.settings.movetime_ms;
                    step.commands.push(EngineCommand::Go {
                        movetime_ms: (ms > 0).then_some(ms),
                    });
                    target.started = true;
                    self.engine = Engine::Searching(target.id);
                }
            }
            _ if !target.started && !target.finished && target.local_at_ms > now_ms => {
                step.wake_at_ms = Some(target.local_at_ms);
            }
            _ => {}
        }
        step
    }

    fn cloud_for(&self, epd: &Epd) -> Option<&CloudEval> {
        self.cloud
            .as_ref()
            .filter(|(cloud_epd, _)| cloud_epd == epd)
            .map(|(_, eval)| eval)
    }

    /// A cloud eval deep enough, with every line asked for, makes the local search unneeded.
    fn cloud_is_enough(&self, target: &Target) -> bool {
        let wanted = (target.settings.lines as usize).min(target.legal_moves);
        self.cloud_for(&target.epd)
            .is_some_and(|eval| eval.depth >= CLOUD_DEEP_ENOUGH && eval.pvs.len() >= wanted)
    }

    /// What to show now.
    pub fn lines(&self) -> EngineLines {
        let Some(target) = &self.target else {
            return EngineLines::default();
        };
        let wanted = target.settings.lines as usize;
        let local: Vec<&LocalLine> = self.local.iter().map_while(Option::as_ref).collect();
        let local_depth = local.first().map_or(0, |line| line.depth);
        let cloud = self.cloud_for(&target.epd);
        let use_local = !local.is_empty()
            && cloud.is_none_or(|cloud| {
                local_depth > cloud.depth
                    || (cloud.pvs.len() < wanted.min(target.legal_moves)
                        && local_depth >= LOCAL_OVER_SHORT_CLOUD_DEPTH)
            });
        let searching = self.engine == Engine::Searching(target.id);
        let ply = ply_of(&target.position);
        if use_local {
            return EngineLines {
                lines: local
                    .iter()
                    .map(|line| pv_line(&target.position, ply, line.score, &line.pv))
                    .collect(),
                depth: local_depth,
                source: Some(EvalSource::Local),
                searching,
                knps: self.nps.map(|nps| nps / 1000),
            };
        }
        let Some(cloud) = cloud else {
            return EngineLines {
                searching,
                ..EngineLines::default()
            };
        };
        let lines = cloud
            .pvs
            .iter()
            .filter_map(|pv| {
                let score = pv.mate.map(Score::Mate).or(pv.cp.map(Score::Cp))?;
                let moves: Vec<String> = pv.moves.split_whitespace().map(str::to_owned).collect();
                Some(pv_line(&target.position, ply, score, &moves))
            })
            .take(wanted)
            .collect();
        EngineLines {
            lines,
            depth: cloud.depth,
            source: Some(EvalSource::Cloud),
            searching,
            knps: None,
        }
    }
}

fn ply_of(position: &ChessPosition) -> usize {
    let fullmove = position.fullmove_number().max(1) as usize;
    (fullmove - 1) * 2 + usize::from(position.side_to_move() == Side::Black)
}

/// The legal start of `pv` in SAN; an engine's or server's illegal move ends the line.
fn pv_line(position: &ChessPosition, ply: usize, score: Score, pv: &[String]) -> PvLine {
    let mut moves = Vec::new();
    let mut current = position.clone();
    for uci in pv.iter().take(MAX_LINE_MOVES) {
        let Some((played, next)) = current.play_uci(uci) else {
            break;
        };
        moves.push(played);
        current = next;
    }
    PvLine {
        score,
        eval: score.text(),
        text: move_list(&moves, ply),
        moves,
    }
}
