//! The light flavour, for real: handshake, a MultiPV search, and the core reading its output.

use std::sync::mpsc;
use std::time::Duration;

use orbt_core::chess::ChessPosition;
use orbt_core::engine::{EngineKind, EngineSearch, EngineSettings, EvalSource};
use orbt_engine::{EngineBackend, Flavour, Stockfish, network_is_valid};

fn wait_for(lines: &mpsc::Receiver<String>, prefix: &str) -> Vec<String> {
    let mut seen = Vec::new();
    loop {
        let line = lines
            .recv_timeout(Duration::from_secs(60))
            .unwrap_or_else(|_| panic!("no {prefix:?} after {seen:?}"));
        let done = line.starts_with(prefix);
        seen.push(line);
        if done {
            return seen;
        }
    }
}

#[test]
fn light_stockfish_searches_with_three_lines() {
    let (tx, lines) = mpsc::channel();
    let mut engine = Stockfish::start(Flavour::Light, move |line| {
        let _ = tx.send(line.to_owned());
    })
    .unwrap();
    // A flavour runs once at a time.
    assert!(Stockfish::start(Flavour::Light, |_| {}).is_err());

    let mut search = EngineSearch::new(EngineKind::Stockfish);
    let settings = EngineSettings {
        cloud: false,
        movetime_ms: 0,
        threads: 1,
        hash_mb: 16,
        lines: 3,
    };
    for command in search.start().commands {
        engine.write(&command.line()).unwrap();
    }
    for line in wait_for(&lines, "uciok") {
        search.on_line(&line, 0);
    }
    let moves = vec!["e2e4".to_owned(), "e7e5".to_owned()];
    for command in search
        .analyse(ChessPosition::START_FEN, &moves, &settings, 0)
        .commands
    {
        // Searching to a depth keeps the test quick and deterministic.
        let line = command.line().replace("go infinite", "go depth 12");
        engine.write(&line).unwrap();
    }
    for line in wait_for(&lines, "bestmove") {
        search.on_line(&line, 1);
    }
    let shown = search.lines();
    assert_eq!(shown.source, Some(EvalSource::Local));
    assert_eq!(shown.lines.len(), 3);
    assert!(shown.depth >= 12, "{shown:?}");
    assert!(shown.lines.iter().all(|l| l.text.starts_with("2. ")));
    engine.quit();

    // Started again after quitting.
    let mut again = Stockfish::start(Flavour::Light, |_| {}).unwrap();
    again.quit();
}

#[test]
fn a_full_net_must_match_its_name() {
    let dir = std::env::temp_dir().join(format!("orbt-engine-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let fake = dir.join("nn-1a298aa575a0.nnue");
    std::fs::write(&fake, b"not a net").unwrap();
    assert!(!network_is_valid(&fake));
    assert!(Stockfish::start(Flavour::Full(fake), |_| {}).is_err());
    // The light net is named after its hash too.
    let light =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("vendor/nnue/nn-61e7af4bb97d.nnue");
    assert!(network_is_valid(&light));
    std::fs::remove_dir_all(dir).unwrap();
}
