//! The engine conversation: when the local engine searches, what is shown, cloud evals first.

use ot_core::chess::ChessPosition;
use ot_core::engine::{
    CLOUD_WAIT_MS, EngineCommand, EngineKind, EngineSearch, EngineSettings, EvalSource,
};
use ot_core::lichess::cloud_eval::{CloudEval, Pv};

const START: &str = ChessPosition::START_FEN;

fn ucis(moves: &[&str]) -> Vec<String> {
    moves.iter().map(|m| (*m).to_owned()).collect()
}

fn lines(commands: &[EngineCommand]) -> Vec<String> {
    commands.iter().map(EngineCommand::line).collect()
}

/// An engine past its handshake.
fn ready() -> EngineSearch {
    let mut search = EngineSearch::new(EngineKind::Stockfish);
    assert_eq!(lines(&search.start().commands), ["uci"]);
    search.on_line("id name Stockfish 19", 0);
    search.on_line("option name MultiPV type spin default 1 min 1 max 256", 0);
    assert!(search.on_line("uciok", 0).commands.is_empty());
    search
}

fn cloud(depth: u32, pvs: &[(&str, i32)]) -> CloudEval {
    CloudEval {
        depth,
        pvs: pvs
            .iter()
            .map(|(moves, cp)| Pv {
                moves: (*moves).to_owned(),
                cp: Some(*cp),
                mate: None,
            })
            .collect(),
    }
}

fn epd_after(moves: &[&str]) -> ot_core::chess::Epd {
    let mut position = ChessPosition::start();
    for m in moves {
        position = position.play_uci(m).unwrap().1;
    }
    position.epd()
}

#[test]
fn waits_for_the_cloud_then_searches_with_the_options() {
    let mut search = ready();
    let moves = ucis(&["e2e4", "e7e5", "g1h3"]);
    let step = search.analyse(START, &moves, &EngineSettings::default(), 1000);
    assert!(step.commands.is_empty());
    assert_eq!(step.wake_at_ms, Some(1000 + CLOUD_WAIT_MS));
    assert!(search.poll(1100).commands.is_empty());

    let step = search.poll(1000 + CLOUD_WAIT_MS);
    assert_eq!(
        lines(&step.commands),
        [
            "setoption name Threads value 2",
            "setoption name Hash value 64",
            "setoption name MultiPV value 3",
            "position fen rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 moves e2e4 e7e5 g1h3",
            "go movetime 6000",
        ]
    );

    // Black to move: the engine's +0.8 for Black is -0.8 for White.
    search.on_line(
        "info depth 14 seldepth 20 multipv 1 score cp 80 nodes 100000 nps 500000 time 200 pv d7d5 d2d3 g8f6",
        1700,
    );
    search.on_line(
        "info depth 14 multipv 2 score cp 60 upperbound pv b8c6",
        1700,
    );
    search.on_line("info depth 14 multipv 2 score cp 55 pv b8c6 f1c4", 1700);
    let shown = search.lines();
    assert_eq!(shown.source, Some(EvalSource::Local));
    assert!(shown.searching);
    assert_eq!(shown.depth, 14);
    assert_eq!(shown.knps, Some(500));
    assert_eq!(shown.eval(), Some("-0.8"));
    assert_eq!(shown.lines[0].text, "2… d5 3. d3 Nf6");
    assert_eq!(shown.lines[1].text, "2… Nc6 3. Bc4");
    assert_eq!(shown.lines[1].eval, "-0.6");

    search.on_line("bestmove d7d5 ponder d2d3", 7600);
    assert!(!search.lines().searching);
    // The same position again: nothing to do.
    assert_eq!(
        search.analyse(START, &moves, &EngineSettings::default(), 8000),
        Default::default()
    );
}

#[test]
fn a_new_position_stops_the_search_and_drops_its_late_output() {
    let mut search = ready();
    let settings = EngineSettings {
        cloud: false,
        ..EngineSettings::default()
    };
    let step = search.analyse(START, &ucis(&["e2e4"]), &settings, 0);
    assert_eq!(lines(&step.commands).last().unwrap(), "go movetime 6000");

    let step = search.analyse(START, &ucis(&["e2e4", "c7c5"]), &settings, 10);
    assert_eq!(lines(&step.commands), ["stop"]);
    search.on_line("info depth 20 multipv 1 score cp 30 pv c7c5", 11);
    assert!(search.lines().lines.is_empty());

    let step = search.on_line("bestmove c7c5", 12);
    assert_eq!(
        lines(&step.commands),
        [
            "position fen rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 moves e2e4 c7c5",
            "go movetime 6000",
        ]
    );
    search.on_line("info depth 8 multipv 1 score cp 30 pv g1f3", 13);
    assert_eq!(search.lines().lines[0].text, "2. Nf3");
}

#[test]
fn a_deep_cloud_eval_means_no_local_search() {
    let mut search = ready();
    let moves = ucis(&["e2e4"]);
    search.analyse(START, &moves, &EngineSettings::default(), 0);
    let deep = cloud(
        40,
        &[("e7e5 g1f3", 25), ("c7c5 g1f3", 30), ("e7e6 d2d4", 40)],
    );
    let step = search.on_cloud(&epd_after(&["e2e4"]), Some(deep), 100);
    assert_eq!(step, Default::default());
    assert!(search.poll(10_000).commands.is_empty());
    let shown = search.lines();
    assert_eq!(shown.source, Some(EvalSource::Cloud));
    assert_eq!(shown.depth, 40);
    assert_eq!(shown.eval(), Some("+0.2"));
    assert_eq!(shown.lines[0].text, "1… e5 2. Nf3");
    assert!(!shown.searching);
}

#[test]
fn a_deep_cloud_eval_arriving_late_stops_the_search() {
    let mut search = ready();
    search.analyse(START, &ucis(&["d2d4"]), &EngineSettings::default(), 0);
    assert!(!search.poll(CLOUD_WAIT_MS).commands.is_empty());
    let deep = cloud(35, &[("g8f6", 20), ("d7d5", 25), ("e7e6", 30)]);
    let step = search.on_cloud(&epd_after(&["d2d4"]), Some(deep), 700);
    assert_eq!(lines(&step.commands), ["stop"]);
}

#[test]
fn a_shallow_cloud_eval_shows_until_the_engine_is_deeper() {
    let mut search = ready();
    search.analyse(START, &ucis(&["e2e4"]), &EngineSettings::default(), 0);
    let shallow = cloud(22, &[("e7e5", 20), ("c7c5", 30), ("e7e6", 40)]);
    search.on_cloud(&epd_after(&["e2e4"]), Some(shallow), 50);
    search.poll(CLOUD_WAIT_MS);
    search.on_line("info depth 20 multipv 1 score cp -10 pv c7c5", 900);
    assert_eq!(search.lines().source, Some(EvalSource::Cloud));
    search.on_line("info depth 23 multipv 1 score cp -10 pv c7c5", 900);
    let shown = search.lines();
    assert_eq!(shown.source, Some(EvalSource::Local));
    assert_eq!(shown.eval(), Some("+0.1"));
}

#[test]
fn settings_are_sent_only_when_they_change_and_mate_needs_no_search() {
    let mut search = ready();
    let mut settings = EngineSettings {
        cloud: false,
        lines: 9,
        ..EngineSettings::default()
    };
    let step = search.analyse(START, &ucis(&["e2e4"]), &settings, 0);
    assert!(lines(&step.commands).contains(&"setoption name MultiPV value 5".to_owned()));
    search.on_line("bestmove e7e5", 1);
    settings.lines = 2;
    let step = search.analyse(START, &ucis(&["e2e4"]), &settings, 2);
    assert!(lines(&step.commands).contains(&"setoption name MultiPV value 2".to_owned()));
    assert!(!lines(&step.commands).iter().any(|l| l.contains("Hash")));
    search.on_line("bestmove e7e5", 3);

    // Fool's mate: nothing to search.
    let mated = ucis(&["f2f3", "e7e5", "g2g4", "d8h4"]);
    assert!(
        search
            .analyse(START, &mated, &settings, 4)
            .commands
            .is_empty()
    );
    // An illegal move stops the analysis.
    assert!(
        search
            .analyse(START, &ucis(&["e2e5"]), &settings, 5)
            .commands
            .is_empty()
    );
    assert_eq!(search.lines(), Default::default());
}
