# The Rust core

The core (a Cargo workspace) is the only place for domain rules; the apps call it through
`orbt-ffi`. The rules themselves are in the root `AGENTS.md`.

## Crates
- `orbt-core/` — pure Rust, no IO, no async, no OS APIs; must keep building for wasm32. Modules:
  `chess` (shakmaty), `pgn` (our parser and byte-exact writer), `repertoire` (tree,
  transpositions, merge), `explorer` (stats, sans-IO request queue, cache, offline coverage
  tables and their manifest), `coverage`, `training` (`anki/` is Anki's scheduler; trainer,
  study session, line run), `statistics` (Anki's graphs, scoping, chess stats), `formats`
  (sidecar and revlog), `document` (the open repertoire: edits, undo, save hints, remote merges,
  outline/search), `builder`, `drill` (state machines behind the two main screens), `oauth`
  (PKCE and the redirect back, for every sign-in), `lichess` (sign-in requests, analysis URL,
  cloud evals), `engine` (UCI, which evaluation to show), `analysis` (the analysis board's
  tree), `sync` (the folder synced with Dropbox or Google Drive: a sans-IO loop like the
  explorer queue, each provider a small `Provider` of requests and answers; Dropbox's sign-in
  requests too, and signing out revokes on the server).
- `orbt-engine/` — native only (never wasm): Stockfish 19 vendored from lichess's
  dart-multistockfish (`vendor/PATCHES.md`), built with `cc`, run on a thread over pipes
  behind `EngineBackend` (Leela would be another backend). CPU flags per target in `build.rs`:
  dotprod and AVX2 on Apple, Stockfish's armv8 and x86-64-sse41-popcnt elsewhere; Android's
  arm64 also gets an armv8-dotprod copy of each flavour, started when `getauxval(AT_HWCAP)`
  has the dot product (`Simd`; upstream's arm64-universal build, see `vendor/PATCHES.md`).
  Windows builds with MinGW (`x86_64-pc-windows-gnu`, as Stockfish's own Windows releases;
  `core/.cargo/config.toml` links its runtime statically): the pipes are handles there,
  and `bridge.cpp` opens the C runtime's descriptors on them.
- `orbt-ffi/` — the UniFFI 0.32 bindings: objects (`RepertoireDoc`, `BuilderSession`,
  `DrillSession`, `Explorer`, `Engine`, `AnalysisSession`, `Position`, `Graphs`,
  `LibrarySidecar`, `RepertoireSync`) and the core's records and enums as remote types. Thin:
  conversions and locking only. Swift through `uniffi-bindgen-swift/`, Kotlin through
  `uniffi-bindgen/` and `orbt-ffi/uniffi.toml` (package `org.orbtchess.orbt.core`); an error
  field is never named `message` (Kotlin exceptions have their own).

## Engine and evaluations (`orbt-core/src/engine`, `analysis`; `orbt-engine`)
Lichess's cloud eval first; the local engine waits 600 ms for it, never runs where it is
depth ≥ 30 with every line asked for, and replaces it once deeper (lichess mobile's order).
Stockfish 19 runs in-process (iOS allows no child processes): the light flavour with its
1.1 MB net built in, or the full one with the 94 MB net downloaded in Settings (checked against
its name first: Stockfish exits the process when a net does not load). Settings: search time,
lines (1–5), cloud evals.

## Offline coverage tables (`explorer::table`, OTCB files)
A repertoire's coverage database is one time control and one rating bin — Blitz or Rapid
(Lichess games, Lichess rating) or Classical (over-the-board games since 2000 by FIDE rating,
Lumbra's Gigabase, CC BY-NC 4.0: credit it, no commercial use). Each table holds the positions
a repertoire can reach at 1 in 800 (Lichess: own moves ≥ 5%, lines stop below 25 games;
Classical: every own move, below 10 games), downloaded from Cloudflare R2 (`manifest.json`,
written by `scripts/coverage-manifest.py`; always the deepest file) into Application
Support/Coverage when chosen or when a repertoire using it opens. The stats cache answers from
Lichess-fetched entries first, then the table (Classical: the table first, Lichess is only its
backup); while a table downloads nothing is fetched for its database; positions in the table
are never queued, and queued requests a new table answers are dropped. Positions it lacks still
come from the explorer (Classical: the masters explorer from 2000, Lichess rapid games one bin
up below). The tables are built outside this repo (`tools/coverage-tables/`; data never
committed).

The coverage check is bounded by the target, not PGN size: the 3.8k-move Berlin test PGN needs
136 requests at 1-in-400 and 156 at 1-in-500, about 8-9 minutes at 3.5 s.

## Tests
- `orbt-core/tests/*.rs` state the rules; `orbt-core/tests/snapshot_*.rs` are insta snapshot
  tests over the inputs in `orbt-core/tests/data/`, including every line of lichess's opening
  names as one large repertoire (`data/repertoires/`, CC0) (snapshots in `tests/snapshots/`;
  after an intended change, `cargo insta review` or `INSTA_UPDATE=always cargo test`, then read
  the diff).
- `DEVIATIONS.md` lists where the core differs from Anki/lichess.
- `fuzz/` — cargo-fuzz targets for what the app reads (PGN, sidecar, review log, explorer
  answers, engine output, storage provider answers), outside the workspace; `fuzz/run.sh
  [seconds]` runs them all (nightly). The core must not panic or recurse per ply on any input:
  the app calls it on small stacks, and a panic or overflow in a non-throwing call crashes it on
  every launch.

## Tooling and scripts
- `rust-toolchain.toml` pins the Rust version, components and targets; `deny.toml` configures
  cargo-deny (licenses compatible with AGPL-3.0-or-later, RustSec advisories, bans, sources).
- `scripts/check.sh` — fmt, clippy -D warnings, tests, wasm32 check, cargo deny (needs
  `cargo install --locked cargo-deny` once). Run before committing Rust changes.
- `scripts/build-apple.sh` — after changing Rust code and once after cloning (Rust from
  rustup, which installs the pinned toolchain): builds the iOS, iOS simulator and macOS slices,
  regenerates the Swift bindings, and runs `scripts/acknowledgements.py` (the linked crates and
  their license texts in the app's `UI/Settings/Acknowledgements.json`). `swift test` in
  `apple/OpeningCoreRust` smoke-tests the bindings.
- `scripts/build-android.sh [--debug]` — after changing the FFI (needs the Android NDK from
  Android Studio's SDK Manager): Android's `.so`s, the host library for JVM tests and the
  desktop app, the Kotlin bindings, and Android's `Acknowledgements.json`.
- `scripts/git-hooks/` — on with `git config core.hooksPath core/scripts/git-hooks`: rebuild
  the xcframework when a merge, pull, rebase or branch switch changes the core, so it never lags
  the committed bindings; a new worktree copies another worktree's xcframework when
  `scripts/core-fingerprint.sh` matches the one `build-apple.sh` recorded, instead of building.
