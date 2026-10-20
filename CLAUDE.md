# Opening Trainer

Open-source (AGPL-3.0), subscription-free alternative to Chessbook for iPhone, iPad and Mac.
A Rust core shared by every platform, with a SwiftUI app (iOS/iPadOS 26 and native macOS 26,
Liquid Glass) on top. Repertoires are PGN files in iCloud Drive; opponent statistics come from
the Lichess opening explorer. Later platforms and sync are in `FUTURE.md`.

## How the owner uses the app (product guidance — every feature serves this)
1. Read a book or watch a video on an opening.
2. Enter its moves, including the opponent responses and the branches it explains.
3. When unsure why a move fails for the opponent, open the position in Lichess analysis
   (one tap, keeps the move history).
4. Come back and add the crucial lines they personally want to cover.
5. Train with spaced repetition, or drill everything under one branch.

Priorities, in order:
1. See which opponent moves are not covered yet (gaps), with "seen every N games".
2. Navigate the repertoire easily and add new lines quickly.
3. Hand off a position to Lichess analysis in one tap.
4. Spaced-repetition training, including training a single branch. Works offline.
5. Separate progress for building (coverage) and for learning (cards).

Requirements:
- Lichess stats are cached by EPD (FEN without move counters; ep square only if an
  en-passant capture is legal).
- A repertoire is a PGN in the app's folder (iCloud Drive, or Documents without iCloud):
  created there, or imported (copied in) from Files.
  Every edit is saved to the PGN immediately. Settings and training state live in a
  sidecar `<Name>.otrep.json`, never in the PGN; the review log is `<Name>.otlog.jsonl`
  (append-only, one Anki revlog entry per line).
- Each repertoire chooses its coverage database (masters, or Lichess speeds + rating
  buckets) and its coverage target ("cover moves seen once in N games").
- Chessbook screenshots only show how that app works; its layout is not a template.

Non-goals for now: auto gap filling, online game review, daily tasks, plans in a
position, model games, bundled engine.

## Layout
One folder per platform around a shared core (Android and web would be `android/`, `web/`).
- `core/` — the Rust core (Cargo workspace), the only place for domain rules:
  - `ot-core/` — pure Rust, no IO, no async, no OS APIs; must keep building for wasm32. Modules:
    `chess` (shakmaty), `pgn` (our parser and byte-exact writer), `repertoire` (tree,
    transpositions, merge), `explorer` (stats, sans-IO request queue, cache), `coverage`,
    `training` (`anki/` is Anki's scheduler; trainer, study session, line run), `statistics`
    (Anki's graphs, scoping, chess stats), `formats` (sidecar and revlog), `document` (the open repertoire: edits, undo, save hints, remote merges,
    outline/search), `builder`, `drill` (state machines behind the two main screens), `lichess`
    (PKCE, analysis URL).
  - `ot-ffi/` — the UniFFI 0.32 bindings: objects (`RepertoireDoc`, `BuilderSession`,
    `DrillSession`, `Explorer`, `Position`, `Graphs`, `LibrarySidecar`) and the core's records
    and enums as remote types. Thin: conversions and locking only.
  - Tests: `ot-core/tests/*.rs` state the rules; `ot-core/tests/snapshot_*.rs` are insta
    snapshot tests over the inputs in `ot-core/tests/data/` and `testData/` (snapshots in
    `tests/snapshots/`; after an intended change, `cargo insta review` or
    `INSTA_UPDATE=always cargo test`, then read the diff). `DEVIATIONS.md` lists where the core
    differs from Anki/lichess.
  - `rust-toolchain.toml` pins the Rust version, components and targets; `deny.toml` configures
    cargo-deny (licenses compatible with AGPL-3.0-or-later, RustSec advisories, bans, sources).
  - `scripts/check.sh` (fmt, clippy -D warnings, tests, wasm32 check, cargo deny),
    `scripts/build-apple.sh`.
  - `fuzz/` — cargo-fuzz targets for what the app reads (PGN, sidecar, review log, explorer
    answers), outside the workspace; `fuzz/run.sh [seconds]` runs them all (nightly).
    The core must not panic or recurse per ply on any input: the app calls it on small
    stacks, and a panic or overflow in a non-throwing call crashes it on every launch.
- `apple/` — the iPhone, iPad and Mac app (one multiplatform target, not Catalyst):
  - `openingTrainer.xcodeproj`; `openingTrainer/` is the app target (folder-synced group, new
    files are picked up automatically): `Lichess/`, `Storage/`, `UI/`. `Config/` holds the
    Info.plist and the iOS and macOS entitlements (same iCloud container; macOS sandboxed).
  - The Swift side does IO and platform work only: files (NSFileCoordinator, iCloud conflict
    versions, handed to the core to merge), URLSession for the core's requests, Keychain and
    web sign-in, the SwiftData stats cache, timers (save debounce from the core's `Changes`, the
    drill's step clock), UserDefaults and the UI. Models (`RepertoireDocument`, `BuilderModel`,
    `DrillModel`, `StatisticsModel`, `ExplorerService`) are thin `@Observable` wrappers that
    forward to the core and re-read it when its revision changes.
  - `openingTrainerTests/` — Swift Testing target hosted in the app (folder-synced): conflict
    merging and file presenters over a temporary folder.
  - `UI/Components/Platform.swift` — the few iOS-only modifiers and what macOS uses instead.
  - `OpeningCoreRust/` — Swift package over the Rust core: the xcframework (built, not
    committed), the generated `opening_core.swift` (never edit by hand) and `Additions.swift`
    (hand-written conveniences: names, conformances; no rules).
- `Design/` — app icon sources.
- `testData/` — real repertoires for testing by hand and timing (`OT_LARGE_PGN`): a 3.8k-move
  Berlin and a 1.2 MB Chessbook Semi-Slav export.
- `FUTURE.md` — web, Android, other storage providers, a sync server.

## Transpositions (see `repertoire::tree`, `RepertoireTree::merge`)
Each position's lines are stored once. When a PGN move order reaches a position whose
lines already exist at another node (not an ancestor), that node becomes a
leaf and its PGN moves are merged into the existing one (`transpositionTarget`). Chessbook
exports repeat the subtree under every move order (a 1.2 MB Semi-Slav: 189k moves, 5.5k
positions); such a file is rewritten compactly after opening. Coverage counts a leaf with a
target as `.transposition`, training lines and branch drills continue through it, and the
builder shows the target's moves and adds new moves there.
A repertoire is one game: when a PGN holds several games, those from the standard position
are merged into one tree (the first game's tags kept, the others' dropped) and saved as one
game; games from another position (SetUp/FEN) are kept verbatim and written back unchanged.

## Coverage model (see `core/ot-core/src/coverage`)
Reach probability p: root 1; own moves keep p; opponent move multiplies by its share at
the parent (move games / position games). Opponent reply required when p·f ≥ 1/N and the
position has ≥ minGames games. Gaps: own-turn node with p ≥ 1/N and no saved move (and no
transposition), or a missing required reply. Completion C is the frequency-weighted mean
over required replies. Opponent moves the user excludes (sidecar `excludedMoves`, keyed by
the EPD before the move, so they apply at every transposition) are never required; a move
saved anyway is covered as usual. Values are cached per node and updated incrementally: an edit
recomputes only the edited subtree and its ancestors.

## Training (see `core/ot-core/src/training/anki`, ported from Anki's rslib scheduler)
Follow Anki's code, not invented rules. A card is a position where it's your move (one per
EPD). States, learning steps (1m 10m, relearn 10m), FSRS-6, fuzz, day rollover at 4 AM,
learn-ahead 20 min, queue order and daily limits are Anki's. The defaults (Anki's preset) are
edited in Settings; a repertoire's options set its own limits; one-day changes are custom study
(Study More Today). Chess additions, kept minimal and listed in `training/study.rs`: lines start at move 1
(or take back to where they part from the last line, when shorter) and the practice mode
decides who plays your earlier moves; one line answers every queued card on it; moves you play that aren't due are reviews ahead (filtered deck); new cards are
introduced a line at a time (most reached first) and a started line is finished past the
daily limit; reviews due the same day are ordered by reach. Grading is Again/Good only
(wrong, hint or browsing = Again). Files ported from Anki (or another project) keep its AGPL
copyright header naming the source files, in Rust as before in Swift (see `training/anki/*.rs`,
`statistics/mod.rs`); differences from the source go in `core/DEVIATIONS.md`.
The UI follows Anki's deck list → deck overview → deck options, and says "moves", never
"cards". Progress uses Anki's card-count groups (learning, young, mature), not a percentage.
Study All runs repertoires one after another (Anki would mix a parent deck's reviews).

## Conventions
- Rules belong in `ot-core`, with Rust tests; Swift never re-implements them. When the app
  needs a new rule or query, add it to the core and expose it through `ot-ffi`.
- `ot-core` takes time as arguments (`SchedTiming`, unix ms) and returns what to do
  (`Changes` with save delays, explorer `Fetch`es); the platform runs the IO and timers.
- App code is MainActor by default (`SWIFT_DEFAULT_ACTOR_ISOLATION`). Core objects are called
  from the main actor; foreign callbacks (`DocumentListener`, `ExplorerListener`) hop to it.
  File IO and heavy core calls (opening, saving, remote merges) run off the main actor: a
  document's `Writer` runs them one at a time, and each coordinated access passes that file's
  presenter. `ExplorerCacheStore` is thread-agnostic (the core calls it from any thread).
- iCloud conflict versions are merged, then removed: the PGN into the document, the sidecar
  with `mergeSidecarData` and the review log with `mergeRevlogData`.
- Explorer: the position on screen is fetched directly after 300 ms on screen (no queue). The coverage check is a separate queue, one request at a time, one every 1.2 s (Lichess allows ~20/min per user, measured, so expect 429s). A 429 from either pauses both for 60 s (kept across launches) and slows the coverage pace for good; re-login on 401.
- Fetch policy: the position on screen first; plus a background coverage check only while one of
  the repertoire's screens is showing (overview, builder, study), limited to opponent-to-move positions above the target
  (bounded by the target, not PGN size: the 3.8k-move Berlin test PGN needs 136 requests at
  1-in-400 and 156 at 1-in-500, about 8-9 minutes at 3.5 s).
  Never fetch every position of a PGN.
  Cached stats never expire for now (the core keeps every entry it loads; there is no age check).
- Build:
  1. `core/scripts/build-apple.sh` after changing Rust code and once after cloning (Rust from
     rustup, which installs the pinned toolchain; it builds iOS, iOS simulator and macOS slices
     and regenerates the bindings). `swift test` in `apple/OpeningCoreRust` smoke-tests the
     bindings.
  2. `core/scripts/check.sh` before committing Rust changes (needs
     `cargo install --locked cargo-deny` once).
  3. `xcodebuild -project apple/openingTrainer.xcodeproj -scheme openingTrainer -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' build`
     (iPad: `name=iPad Pro 13-inch (M5)`; Mac: `-destination 'platform=macOS'`, which needs a
     Mac development profile for the iCloud entitlement, or `CODE_SIGNING_ALLOWED=NO` to compile
     only).
  A Claude Code hook (`.claude/hooks/check-before-commit.sh`) runs the ones a commit needs before
  every `git commit` and blocks it on failure: check.sh for `core/`, build-apple.sh for
  `core/ot-ffi/` or Cargo.lock (the committed bindings must be up to date), the simulator build
  for `apple/` or the FFI. A blocked commit is fixed, not bypassed.
