//! The local engine for the analysis board: `ot_core::engine` decides what to say, `ot_engine`
//! runs Stockfish. The engine's output arrives on its reader thread, goes straight into the
//! core, and the listener is told the lines changed; the platform runs only the cloud eval
//! request and the timer for `wake_at_ms`.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, Weak};
use std::time::{SystemTime, UNIX_EPOCH};

use ot_core::chess::Epd;
use ot_core::engine::{EngineKind, EngineLines, EngineSearch, EngineSettings, EngineStep};
use ot_core::lichess::cloud_eval::CloudEval;
use ot_engine::{EngineBackend, Flavour, Stockfish};

#[uniffi::export(with_foreign)]
pub trait EngineListener: Send + Sync {
    /// The lines to show changed (called from the engine's thread).
    fn changed(&self);
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum EngineFailure {
    #[error("{0}")]
    Failed(String),
}

struct State {
    search: EngineSearch,
    backend: Option<Box<dyn EngineBackend>>,
    /// Which start the running backend's output belongs to.
    generation: u64,
    net: Option<String>,
}

#[derive(uniffi::Object)]
pub struct Engine {
    kind: EngineKind,
    state: Arc<Mutex<State>>,
    listener: Arc<Mutex<Option<Arc<dyn EngineListener>>>>,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

impl State {
    fn run(&mut self, step: EngineStep) -> Option<u64> {
        if let Some(backend) = &mut self.backend {
            for command in &step.commands {
                // A failed write means the engine is gone; the next start replaces it.
                let _ = backend.write(&command.line());
            }
        }
        step.wake_at_ms
    }
}

fn notify(listener: &Mutex<Option<Arc<dyn EngineListener>>>) {
    let listener = listener.lock().expect("listener lock").clone();
    if let Some(l) = listener {
        l.changed();
    }
}

impl Engine {
    fn with<R>(&self, f: impl FnOnce(&mut State) -> R) -> R {
        f(&mut self.state.lock().expect("engine lock"))
    }
}

#[uniffi::export]
impl Engine {
    #[uniffi::constructor]
    pub fn new(kind: EngineKind) -> Arc<Engine> {
        Arc::new(Engine {
            kind,
            state: Arc::new(Mutex::new(State {
                search: EngineSearch::new(kind),
                backend: None,
                generation: 0,
                net: None,
            })),
            listener: Arc::new(Mutex::new(None)),
        })
    }

    pub fn set_listener(&self, listener: Arc<dyn EngineListener>) {
        *self.listener.lock().expect("listener lock") = Some(listener);
    }

    /// Starts the engine, with the full net at `net_path` or the built-in light one; nothing
    /// happens if it already runs with that net.
    pub fn start(&self, net_path: Option<String>) -> Result<(), EngineFailure> {
        let old = self.with(|s| {
            if s.backend.is_some() && s.net == net_path {
                return None;
            }
            s.generation += 1;
            Some(s.backend.take())
        });
        let Some(old) = old else { return Ok(()) };
        // Quit outside the lock: the old reader thread may be waiting for it.
        drop(old);

        let generation = self.with(|s| s.generation);
        let state: Weak<Mutex<State>> = Arc::downgrade(&self.state);
        let listener = Arc::clone(&self.listener);
        let on_line = move |line: &str| {
            let Some(state) = state.upgrade() else { return };
            {
                let mut s = state.lock().expect("engine lock");
                if s.generation != generation {
                    return;
                }
                let step = s.search.on_line(line, now_ms());
                s.run(step);
            }
            if line.starts_with("info") || line.starts_with("bestmove") {
                notify(&listener);
            }
        };
        let flavour = match &net_path {
            Some(path) => Flavour::Full(PathBuf::from(path)),
            None => Flavour::Light,
        };
        let backend: Box<dyn EngineBackend> = match self.kind {
            EngineKind::Stockfish => Box::new(
                Stockfish::start(flavour, on_line)
                    .map_err(|e| EngineFailure::Failed(e.to_string()))?,
            ),
            EngineKind::Leela => {
                return Err(EngineFailure::Failed("Leela is not built in yet".into()));
            }
        };
        self.with(|s| {
            s.search = EngineSearch::new(self.kind);
            let setup = backend.setup();
            s.backend = Some(backend);
            s.net = net_path;
            let step = s.search.start();
            s.run(step);
            if let Some(backend) = &mut s.backend {
                for line in setup {
                    let _ = backend.write(&line);
                }
            }
        });
        Ok(())
    }

    /// The engine's name, None while it is not running.
    pub fn name(&self) -> Option<String> {
        self.with(|s| s.backend.as_ref().map(|b| b.name()))
    }

    /// Analyses the position after `moves` (UCI) from `start_fen`. Returns when to call
    /// `poll` if nothing else happens before.
    pub fn analyse(
        &self,
        start_fen: String,
        moves: Vec<String>,
        settings: EngineSettings,
        now_ms: u64,
    ) -> Option<u64> {
        let wake = self.with(|s| {
            let step = s.search.analyse(&start_fen, &moves, &settings, now_ms);
            s.run(step)
        });
        notify(&self.listener);
        wake
    }

    /// The cloud eval for `epd` (None: none, or not reachable).
    pub fn on_cloud(&self, epd: Epd, eval: Option<CloudEval>, now_ms: u64) -> Option<u64> {
        let wake = self.with(|s| {
            let step = s.search.on_cloud(&epd, eval, now_ms);
            s.run(step)
        });
        notify(&self.listener);
        wake
    }

    pub fn poll(&self, now_ms: u64) -> Option<u64> {
        self.with(|s| {
            let step = s.search.poll(now_ms);
            s.run(step)
        })
    }

    /// Stops analysing; the engine keeps running, idle.
    pub fn stop(&self) {
        self.with(|s| {
            let step = s.search.stop();
            s.run(step);
        });
    }

    pub fn lines(&self) -> EngineLines {
        self.with(|s| s.search.lines())
    }

    /// Quits the engine (it starts again with `start`).
    pub fn quit(&self) {
        let old = self.with(|s| {
            s.generation += 1;
            s.net = None;
            s.backend.take()
        });
        drop(old);
    }
}

/// Whether a downloaded Stockfish net is complete and matches its name.
#[uniffi::export]
pub fn engine_network_is_valid(path: String) -> bool {
    ot_engine::network_is_valid(std::path::Path::new(&path))
}
