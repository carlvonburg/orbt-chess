//! Engine output: whatever an engine prints is read during every search.
#![no_main]

use libfuzzer_sys::fuzz_target;
use orbt_core::chess::ChessPosition;
use orbt_core::engine::{EngineKind, EngineSearch, EngineSettings};

fuzz_target!(|data: &[u8]| {
    let text = String::from_utf8_lossy(data);
    let mut search = EngineSearch::new(EngineKind::Stockfish);
    search.start();
    search.on_line("uciok", 0);
    let settings = EngineSettings {
        cloud: false,
        ..EngineSettings::default()
    };
    search.analyse(ChessPosition::START_FEN, &["e2e4".to_owned()], &settings, 0);
    for (i, line) in text.lines().enumerate() {
        search.on_line(line, i as u64);
        let shown = search.lines();
        assert!(shown.lines.len() <= settings.lines as usize);
    }
});
