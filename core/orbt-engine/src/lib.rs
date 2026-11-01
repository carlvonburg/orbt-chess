//! Chess engines run inside the app. iOS allows no child processes, so an engine runs on a
//! thread of its own and talks UCI through a pair of pipes: the platform writes commands,
//! and a reader thread hands each line the engine prints to a callback. What to say to the
//! engine is `orbt_core::engine`'s business, not this crate's.
//!
//! Stockfish 19 comes in two flavours (see `vendor/PATCHES.md`): `Light`, with its 1.1 MB net
//! built in, and `Full`, with the 94 MB net the app downloads. Leela will be another
//! `EngineBackend`.
//!
//! On Android's arm64 each flavour is in the library twice, for ARMv8 and for ARMv8.2 with the
//! dot product (`build.rs`), and the engine starts the one the CPU runs best (`Simd`).
//!
//! On Windows (MinGW) the pipes are Windows handles, and the engine's C runtime opens its own
//! descriptors on them (`bridge.cpp`).

use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
#[cfg(unix)]
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
#[cfg(windows)]
use std::os::windows::io::{FromRawHandle, IntoRawHandle, OwnedHandle, RawHandle};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;

use sha2::{Digest, Sha256};

/// What a flavour's UCI loop reads and writes: a descriptor, or on Windows a handle
/// (`intptr_t`).
#[cfg(unix)]
type Endpoint = libc::c_int;
#[cfg(windows)]
type Endpoint = isize;

unsafe extern "C" {
    fn orbt_sf_light_main(read: Endpoint, write: Endpoint) -> libc::c_int;
    fn orbt_sf_full_main(read: Endpoint, write: Endpoint) -> libc::c_int;
}

#[cfg(all(target_os = "android", target_arch = "aarch64"))]
unsafe extern "C" {
    fn orbt_sf_light_dotprod_main(read: Endpoint, write: Endpoint) -> libc::c_int;
    fn orbt_sf_full_dotprod_main(read: Endpoint, write: Endpoint) -> libc::c_int;
}

/// A flavour's UCI loop on the pipe ends it is given.
type EngineMain = unsafe extern "C" fn(Endpoint, Endpoint) -> libc::c_int;

/// Which copy of Stockfish runs: on Android's arm64 the library holds two (`build.rs`); every
/// other target has one, compiled for what all its devices have.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Simd {
    /// The only copy this target has.
    Native,
    /// Stockfish's `armv8`: any arm64 CPU.
    Armv8,
    /// Stockfish's `armv8-dotprod`: ARMv8.2 with the dot product (`asimddp`).
    Armv8Dotprod,
}

impl Simd {
    /// Linux's `HWCAP_ASIMDDP` on arm64 (`<asm/hwcap.h>`).
    const HWCAP_ASIMDDP: u64 = 1 << 20;

    /// The copy for Android arm64's hardware capabilities (`getauxval(AT_HWCAP)`), chosen as
    /// upstream's `arm64-universal` build does: the dot product only when the kernel reports it.
    pub fn for_arm64_hwcap(hwcap: u64) -> Simd {
        if hwcap & Self::HWCAP_ASIMDDP != 0 {
            Simd::Armv8Dotprod
        } else {
            Simd::Armv8
        }
    }

    /// The copy this device runs.
    pub fn current() -> Simd {
        #[cfg(all(target_os = "android", target_arch = "aarch64"))]
        {
            // SAFETY: getauxval only reads the process's auxiliary vector.
            let hwcap = unsafe { libc::getauxval(libc::AT_HWCAP) };
            Simd::for_arm64_hwcap(hwcap)
        }
        #[cfg(not(all(target_os = "android", target_arch = "aarch64")))]
        {
            Simd::Native
        }
    }

    fn entry(self, flavour: &Flavour) -> EngineMain {
        #[cfg(all(target_os = "android", target_arch = "aarch64"))]
        if self == Simd::Armv8Dotprod {
            return match flavour {
                Flavour::Light => orbt_sf_light_dotprod_main,
                Flavour::Full(_) => orbt_sf_full_dotprod_main,
            };
        }
        let _ = self;
        match flavour {
            Flavour::Light => orbt_sf_light_main,
            Flavour::Full(_) => orbt_sf_full_main,
        }
    }
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
    /// Short, as lichess shows it, with the net's size: "SF 19 · 94 MB", "SF 19 · 1 MB".
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

#[cfg(unix)]
fn pipe() -> Result<(OwnedFd, OwnedFd), EngineError> {
    let mut fds = [0 as libc::c_int; 2];
    // SAFETY: `fds` has room for the two descriptors pipe() writes.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    // SAFETY: pipe() succeeded, so both descriptors are open and owned by nobody else.
    Ok(unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) })
}

/// An anonymous pipe: synchronous handles, which the engine's C runtime can read and write.
#[cfg(windows)]
fn pipe() -> Result<(OwnedHandle, OwnedHandle), EngineError> {
    unsafe extern "system" {
        fn CreatePipe(
            read: *mut RawHandle,
            write: *mut RawHandle,
            attributes: *const std::ffi::c_void,
            size: u32,
        ) -> i32;
    }
    let mut read: RawHandle = std::ptr::null_mut();
    let mut write: RawHandle = std::ptr::null_mut();
    // SAFETY: CreatePipe writes the two handles it creates; no attributes, the default size.
    if unsafe { CreatePipe(&mut read, &mut write, std::ptr::null(), 0) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    // SAFETY: CreatePipe succeeded, so both handles are open and owned by nobody else.
    Ok(unsafe {
        (
            OwnedHandle::from_raw_handle(read),
            OwnedHandle::from_raw_handle(write),
        )
    })
}

/// Runs the UCI loop on the engine's ends of the pipes, and closes them when it returns, which
/// ends the reader with an end of file.
#[cfg(unix)]
fn run_engine(main: EngineMain, input: OwnedFd, output: OwnedFd) {
    // SAFETY: both descriptors stay open until the loop returns; they are dropped after it.
    unsafe { main(input.as_raw_fd(), output.as_raw_fd()) };
}

#[cfg(windows)]
fn run_engine(main: EngineMain, input: OwnedHandle, output: OwnedHandle) {
    // SAFETY: the handles are open and passed on: the engine opens descriptors on them and
    // closes them when the loop returns (bridge.cpp).
    unsafe {
        main(
            input.into_raw_handle() as Endpoint,
            output.into_raw_handle() as Endpoint,
        )
    };
}

impl Stockfish {
    /// Starts the engine; `on_line` gets every line it prints, on a thread of its own, until it
    /// quits.
    pub fn start(
        flavour: Flavour,
        on_line: impl FnMut(&str) + Send + 'static,
    ) -> Result<Stockfish, EngineError> {
        Self::start_copy(flavour, Simd::current(), on_line)
    }

    /// Starts one copy of the flavour; `simd` must be one this device runs.
    fn start_copy(
        flavour: Flavour,
        simd: Simd,
        mut on_line: impl FnMut(&str) + Send + 'static,
    ) -> Result<Stockfish, EngineError> {
        if let Flavour::Full(path) = &flavour
            && !network_is_valid(path)
        {
            return Err(EngineError::BadNetwork(path.clone()));
        }
        let running: &'static AtomicBool = match flavour {
            Flavour::Light => &LIGHT_RUNNING,
            Flavour::Full(_) => &FULL_RUNNING,
        };
        let main = simd.entry(&flavour);
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
                run_engine(main, command_read, output_write);
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
            Flavour::Light => "SF 19 · 1 MB".into(),
            Flavour::Full(_) => "SF 19 · 94 MB".into(),
        }
    }
}

impl Drop for Stockfish {
    fn drop(&mut self) {
        self.quit();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_dot_product_copy_runs_only_where_the_cpu_reports_it() {
        // A Cortex-A53 (ARMv8.0): fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid.
        let a53 = 0b1000_1111_1111;
        assert_eq!(Simd::for_arm64_hwcap(a53), Simd::Armv8);
        assert_eq!(Simd::for_arm64_hwcap(0), Simd::Armv8);
        // Every capability but asimddp.
        assert_eq!(Simd::for_arm64_hwcap(!(1 << 20)), Simd::Armv8);
        // A Cortex-A55 adds atomics (bit 8) and asimddp (bit 20), among others.
        assert_eq!(
            Simd::for_arm64_hwcap(a53 | 1 << 8 | 1 << 20),
            Simd::Armv8Dotprod
        );
    }

    /// Runs on a phone or the emulator (`cargo test --target aarch64-linux-android`, the test
    /// binary pushed with libc++_shared.so): both copies search the same tree, and how fast.
    #[cfg(all(target_os = "android", target_arch = "aarch64"))]
    #[test]
    fn both_arm64_copies_search_the_same_tree() {
        use std::sync::mpsc;
        use std::time::{Duration, Instant};

        fn send(engine: &mut Stockfish, line: &str) {
            engine.write(line).unwrap();
        }
        fn until(lines: &mpsc::Receiver<String>, prefix: &str) -> Vec<String> {
            let mut seen = Vec::new();
            loop {
                let line = lines.recv_timeout(Duration::from_secs(300)).unwrap();
                let done = line.starts_with(prefix);
                seen.push(line);
                if done {
                    return seen;
                }
            }
        }
        /// Nodes searched and milliseconds, over a few fixed-depth searches on one thread.
        fn search(simd: Simd) -> (u64, u128, Vec<String>) {
            let (tx, lines) = mpsc::channel();
            let mut engine = Stockfish::start_copy(Flavour::Light, simd, move |line| {
                let _ = tx.send(line.to_owned());
            })
            .unwrap();
            send(&mut engine, "uci");
            until(&lines, "uciok");
            send(&mut engine, "compiler");
            let compiler = until(&lines, "Compilation settings");
            send(&mut engine, "setoption name Threads value 1");
            send(&mut engine, "setoption name Hash value 16");
            let positions = [
                ("startpos", 20),
                (
                    "fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
                    16,
                ),
                ("fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", 24),
            ];
            let (mut nodes, mut millis) = (0, 0);
            for (position, depth) in positions {
                send(&mut engine, "ucinewgame");
                send(&mut engine, "isready");
                until(&lines, "readyok");
                send(&mut engine, &format!("position {position}"));
                let started = Instant::now();
                send(&mut engine, &format!("go depth {depth}"));
                let output = until(&lines, "bestmove");
                millis += started.elapsed().as_millis();
                let last = output
                    .iter()
                    .rev()
                    .find(|l| l.starts_with("info depth") && l.contains(" nodes "))
                    .unwrap();
                let mut words = last.split_whitespace();
                words.find(|w| *w == "nodes");
                nodes += words.next().unwrap().parse::<u64>().unwrap();
            }
            engine.quit();
            (nodes, millis, compiler)
        }

        let simd = Simd::current();
        eprintln!("this device runs {simd:?}");
        let (nodes, millis, compiler) = search(Simd::Armv8);
        eprintln!("{compiler:?}");
        eprintln!(
            "armv8: {nodes} nodes in {millis} ms, {} nps",
            nodes as u128 * 1000 / millis
        );
        assert!(compiler.iter().all(|l| !l.contains("DOTPROD")));
        if simd == Simd::Armv8Dotprod {
            let (dot_nodes, dot_millis, compiler) = search(Simd::Armv8Dotprod);
            eprintln!("{compiler:?}");
            eprintln!(
                "armv8-dotprod: {dot_nodes} nodes in {dot_millis} ms, {} nps",
                dot_nodes as u128 * 1000 / dot_millis
            );
            assert!(compiler.iter().any(|l| l.contains("NEON_DOTPROD")));
            // The same evaluations, so the same search.
            assert_eq!(dot_nodes, nodes);
        }
    }
}
