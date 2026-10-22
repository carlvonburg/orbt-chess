//! Chess engines run inside the app. iOS allows no child processes, so an engine runs on a
//! thread of its own and talks UCI through a pair of pipes: the platform writes commands,
//! and a reader thread hands each line the engine prints to a callback. What to say to the
//! engine is `ot_core::engine`'s business, not this crate's.
//!
//! Stockfish 19 comes in two flavours (see `vendor/PATCHES.md`): `Light`, with its 1.1 MB net
//! built in, and `Full`, with the 94 MB net the app downloads. Leela will be another
//! `EngineBackend`.

use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;

use sha2::{Digest, Sha256};

unsafe extern "C" {
    fn ot_sf_light_main(read_fd: libc::c_int, write_fd: libc::c_int) -> libc::c_int;
    fn ot_sf_full_main(read_fd: libc::c_int, write_fd: libc::c_int) -> libc::c_int;
}

/// A flavour's engine state is global, so each runs once at a time.
static LIGHT_RUNNING: AtomicBool = AtomicBool::new(false);
static FULL_RUNNING: AtomicBool = AtomicBool::new(false);

/// The Stockfish engine thread's stack: the UCI loop's own (searches run on threads
/// Stockfish starts itself).
const ENGINE_STACK: usize = 8 << 20;

#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("this engine is already running")]
    AlreadyRunning,
    #[error("the network file {0} is missing or does not match its name")]
    BadNetwork(PathBuf),
    #[error("engine IO failed: {0}")]
    Io(#[from] std::io::Error),
}

/// A running engine.
pub trait EngineBackend: Send {
    /// Writes one command (without the newline).
    fn write(&mut self, line: &str) -> Result<(), EngineError>;
    /// Commands to send after `uci`, e.g. the network file.
    fn setup(&self) -> Vec<String>;
    /// "Stockfish 19", "Stockfish 19 · 1 MB net".
    fn name(&self) -> String;
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Flavour {
    /// The small net built in.
    Light,
    /// The full net, loaded from this file (`nn-<first 12 hex digits of its SHA-256>.nnue`).
    Full(PathBuf),
}

/// Whether `path` is a Stockfish net whose content matches its name. The full flavour exits
/// the process when its net does not load, so it never starts without this.
pub fn network_is_valid(path: &Path) -> bool {
    let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
        return false;
    };
    let Some(hash) = name
        .strip_prefix("nn-")
        .and_then(|rest| rest.strip_suffix(".nnue"))
    else {
        return false;
    };
    let Ok(mut file) = File::open(path) else {
        return false;
    };
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 16];
    loop {
        match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => hasher.update(&buffer[..n]),
            Err(_) => return false,
        }
    }
    let digest: String = hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    hash.len() == 12 && digest.starts_with(hash)
}

/// Stockfish on its own thread.
pub struct Stockfish {
    flavour: Flavour,
    input: Option<File>,
    engine: Option<JoinHandle<()>>,
    reader: Option<JoinHandle<()>>,
}

fn pipe() -> Result<(OwnedFd, OwnedFd), EngineError> {
    let mut fds = [0 as libc::c_int; 2];
    // SAFETY: `fds` has room for the two descriptors pipe() writes.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    // SAFETY: pipe() succeeded, so both descriptors are open and owned by nobody else.
    Ok(unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) })
}

impl Stockfish {
    /// Starts the engine; `on_line` gets every line it prints, on a thread of its own, until it
    /// quits.
    pub fn start(
        flavour: Flavour,
        mut on_line: impl FnMut(&str) + Send + 'static,
    ) -> Result<Stockfish, EngineError> {
        if let Flavour::Full(path) = &flavour
            && !network_is_valid(path)
        {
            return Err(EngineError::BadNetwork(path.clone()));
        }
        let (running, main): (&'static AtomicBool, unsafe extern "C" fn(_, _) -> _) = match flavour
        {
            Flavour::Light => (&LIGHT_RUNNING, ot_sf_light_main),
            Flavour::Full(_) => (&FULL_RUNNING, ot_sf_full_main),
        };
        if running.swap(true, Ordering::AcqRel) {
            return Err(EngineError::AlreadyRunning);
        }
        let pipes = pipe().and_then(|commands| Ok((commands, pipe()?)));
        let ((command_read, command_write), (output_read, output_write)) = match pipes {
            Ok(pipes) => pipes,
            Err(error) => {
                running.store(false, Ordering::Release);
                return Err(error);
            }
        };

        let engine = std::thread::Builder::new()
            .name("stockfish".into())
            .stack_size(ENGINE_STACK)
            .spawn(move || {
                // SAFETY: both descriptors stay open until the loop returns; they are closed
                // below, which ends the reader with an end of file.
                unsafe { main(command_read.as_raw_fd(), output_write.as_raw_fd()) };
                drop(command_read);
                drop(output_write);
                running.store(false, Ordering::Release);
            });
        let engine = match engine {
            Ok(handle) => handle,
            Err(error) => {
                running.store(false, Ordering::Release);
                return Err(error.into());
            }
        };
        let reader = std::thread::Builder::new()
            .name("stockfish-output".into())
            .spawn(move || {
                let lines = BufReader::new(File::from(output_read));
                for line in lines.split(b'\n') {
                    let Ok(line) = line else { break };
                    on_line(String::from_utf8_lossy(&line).trim_end());
                }
            })?;
        Ok(Stockfish {
            flavour,
            input: Some(File::from(command_write)),
            engine: Some(engine),
            reader: Some(reader),
        })
    }

    /// Stops the search, quits and waits for the engine's threads.
    pub fn quit(&mut self) {
        if let Some(mut input) = self.input.take() {
            let _ = input.write_all(b"stop\nquit\n");
        }
        if let Some(engine) = self.engine.take() {
            let _ = engine.join();
        }
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}

impl EngineBackend for Stockfish {
    fn write(&mut self, line: &str) -> Result<(), EngineError> {
        let input = self
            .input
            .as_mut()
            .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::BrokenPipe))?;
        // One write per command, so a line is never split between two writers.
        input.write_all(format!("{line}\n").as_bytes())?;
        Ok(())
    }

    fn setup(&self) -> Vec<String> {
        match &self.flavour {
            Flavour::Light => Vec::new(),
            Flavour::Full(path) => {
                vec![format!("setoption name EvalFile value {}", path.display())]
            }
        }
    }

    fn name(&self) -> String {
        match self.flavour {
            Flavour::Light => "Stockfish 19 · 1 MB net".into(),
            Flavour::Full(_) => "Stockfish 19".into(),
        }
    }
}

impl Drop for Stockfish {
    fn drop(&mut self) {
        self.quit();
    }
}
