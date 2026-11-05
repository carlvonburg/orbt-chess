# The Rust core

- `orbt-core` is pure Rust: no IO, no async, no OS APIs, and it must keep building for wasm32.
- It must never panic or recurse per ply on any input: the apps call it on small stacks, and a
  panic in a non-throwing call crashes the app on every launch. `fuzz/run.sh [seconds]` runs the
  fuzz targets (nightly, outside the workspace).
- `orbt-ffi` is thin: conversions and locking only. An error field is never named `message`
  (Kotlin exceptions have their own). After changing it, regenerate both bindings
  (`scripts/build-apple.sh`, `scripts/build-android.sh`).
- `orbt-engine` is native only. Stockfish is vendored from lichess's dart-multistockfish; every
  change to it goes in `vendor/PATCHES.md`. It runs in-process because iOS allows no child
  processes, and Stockfish exits the whole process when a net fails to load, so a net is checked
  against its name before it is given to the engine.
- Evaluations follow lichess mobile: the cloud eval first, the local engine after 600 ms, and
  the deeper one wins.
- Snapshot tests (`orbt-core/tests/snapshot_*.rs`, insta): after an intended change,
  `INSTA_UPDATE=always cargo test` (or `cargo insta review`), then read the diff.
- Classical coverage tables come from Lumbra's Gigabase (CC BY-NC 4.0): credit it, no
  commercial use. The tables are built by `tools/coverage-tables/`; their data is never committed.
- `cargo install --locked cargo-deny` once, for `scripts/check.sh`. Licenses must stay
  compatible with AGPL-3.0-or-later (`deny.toml`).
