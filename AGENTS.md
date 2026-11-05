# ORBT Chess (ORBT: Opening Repertoire Builder & Trainer)

Said "orbit"; website orbtchess.org. Identifiers use the domain: bundle ID `org.orbtchess.orbt`,
iCloud container `iCloud.org.orbtchess.orbt` (the Files folder is "ORBT Chess").
Users see "ORBT Chess" (display and bundle name); code, folders and identifiers say ORBT.

Open-source (AGPL-3.0), subscription-free alternative to Chessbook for iPhone, iPad, Mac,
Android, Windows and Linux. A Rust core shared by every platform; SwiftUI on Apple (iOS/iPadOS 26
and native macOS 26, Liquid Glass), Compose Multiplatform elsewhere. Repertoires are PGN files in
iCloud Drive (or synced with Dropbox or Google Drive); opponent statistics come from the Lichess
opening explorer. Platforms and sync: `docs/PLATFORMS.md`.

Each area has its own instructions: `core/AGENTS.md`, `apple/AGENTS.md`, `android/AGENTS.md`.

## How the owner uses the app (product guidance — every feature serves this)
1. Build an opening, from scratch or from any source: the explorer shows what people play,
   how it scores and the engine's evaluation, so a repertoire can be built in the app alone;
   a book, a video or an imported PGN is one way in, not the way.
2. Enter the moves, including the opponent responses and the branches that matter.
3. When unsure why a move fails for the opponent, open the position on the analysis board
   (one tap, keeps the move history; Stockfish on the device, Lichess one more tap away).
4. Come back and add the crucial lines they personally want to cover.
5. Train with spaced repetition, or drill everything under one branch.

Priorities, in order:
1. See which opponent moves are not covered yet (gaps), with "seen every N games".
2. Navigate the repertoire easily and add new lines quickly.
3. Analyse a position in one tap, from Build or Study, and bring a line back to Build.
4. Spaced-repetition training, including training a single branch. Works offline.
5. Separate progress for building (coverage) and for learning (cards).

Requirements:
- Lichess stats are cached by EPD (FEN without move counters; ep square only if an
  en-passant capture is legal).
- A repertoire is a PGN in the app's folder (iCloud Drive, or Documents without iCloud):
  created there, or imported (copied in) from Files. Every edit is saved to the PGN
  immediately. Settings and training state live in a sidecar `<Name>.otrep.json`, never in the
  PGN; the review log is `<Name>.otlog.jsonl` (append-only, one Anki revlog entry per line).
- Each repertoire chooses its coverage database (masters, or Lichess speeds + rating
  buckets) and its coverage target ("cover moves seen once in N games").

Non-goals for now: auto gap filling, online game review, daily tasks, plans in a
position, model games.

## Layout
- `core/` — the Rust core (Cargo workspace), the only place for domain rules: `orbt-core`
  (pure Rust, no IO), `orbt-engine` (Stockfish), `orbt-ffi` (UniFFI bindings for Swift and Kotlin).
- `apple/` — the iPhone, iPad and Mac app (one multiplatform target, not Catalyst).
- `android/` — Gradle project for Android, Windows and Linux (Compose Multiplatform).
- `Design/` — app icon references, store material; `COLORS.md`, how the app uses color (read
  before any color change).
- `website/` — orbtchess.org. `tools/coverage-tables/` — builds the offline coverage tables.
- `Version.xcconfig` — the version and build number of every platform, nowhere else. One build
  counter for every store: one more per upload, never back.
- `testData/` — ignored by git: personal repertoires for testing by hand and timing
  (`ORBT_LARGE_PGN`). Never commit a personal repertoire.

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

## Coverage model (see `core/orbt-core/src/coverage`)
Reach probability p: root 1; own moves keep p; opponent move multiplies by its share at
the parent (move games / position games). Opponent reply required when p·f ≥ 1/N and the
position has ≥ minGames games (fixed by the database, what its tables are built for: 10 for
Classical, 25 otherwise). Gaps: own-turn node with p ≥ 1/N and no saved move (and no
transposition), or a missing required reply. Completion C is the frequency-weighted mean
over required replies. Opponent moves the user excludes (sidecar `excludedMoves`, keyed by
the EPD before the move, so they apply at every transposition) are never required; a move
saved anyway is covered as usual. Values are cached per node and updated incrementally: an edit
recomputes only the edited subtree and its ancestors.

## Training (see `core/orbt-core/src/training/anki`, ported from Anki's rslib scheduler)
Follow Anki's code, not invented rules. A card is a position where it's your move (one per
EPD). States, learning steps (1m 10m, relearn 10m), FSRS-6, fuzz, day rollover at 4 AM,
learn-ahead 20 min, queue order and daily limits are Anki's. The defaults (Anki's preset) are
edited in Settings; a repertoire's options set its own limits; one-day changes are custom study
(Study More Today). Chess additions, kept minimal and listed in `training/study.rs`: lines start at move 1
(or take back to where they part from the last line, when shorter; else, when the line was
already shown this session, five half-moves before the first move you play) and the practice mode
decides who plays your earlier moves; one line answers every queued card on it; moves you play that aren't due are reviews ahead (filtered deck); new cards are
introduced a line at a time, each to its end with the most reached reply at every opponent move
(the new move order, a setting: the most likely line not learned yet anywhere, by the reach of
the reply it starts with, or one opening at a time, depth first) and a started line is finished past the
daily limit; reviews due the same day are ordered by reach. Grading is Again/Good only
(wrong, hint or browsing = Again). Files ported from Anki (or another project) keep its AGPL
copyright header naming the source files (see `training/anki/*.rs`, `statistics/mod.rs`);
differences from the source go in `core/DEVIATIONS.md`.
The UI follows Anki's deck list → deck overview → deck options, and says "moves", never
"cards". Progress uses Anki's card-count groups (learning, young, mature), not a percentage.
Study All runs repertoires one after another (Anki would mix a parent deck's reviews).
Build's Study menu: Study Branch is Anki's subdeck (today's moves under the position, within
and counted toward the repertoire's limits), Study Repertoire the daily session, Practice a
filtered deck of every studied move under the position (no new moves, no limits).

## Analysis board
Analysis opens from Build and Study on the position on the board, with its move history. Its
tree is never saved: leaving it for Build puts the path to the selected move on the builder as
its draft (saved moves followed, nothing written, `Builder::set_line`); leaving it for Study
drops it (opening it counted as Again, like browsing). Engine details: `core/AGENTS.md`.

## Colors
Views name meanings, never hues: roles (built, learned, learning, new, to do, correct, wrong,
failure, ahead, inactive) resolved by the theme of the app color, which is the tint of every
control. Always with a symbol or text, never color alone. A new meaning takes a role and a row
in `Design/COLORS.md`, which has the rules and every value. The commit hook blocks hue names in
the UI outside the palette files.

## Conventions
- Rules belong in `orbt-core`, with Rust tests; Swift and Kotlin never re-implement them. When
  the app needs a new rule or query, add it to the core and expose it through `orbt-ffi`.
- `orbt-core` takes time as arguments (`SchedTiming`, unix ms) and returns what to do
  (`Changes` with save delays, explorer `Fetch`es); the platform runs the IO and timers.
- Explorer: the position on screen is fetched directly after 300 ms on screen (no queue). The
  coverage check is a separate queue, one request at a time, one every 1.2 s (Lichess allows
  ~20/min per user, measured, so expect 429s), only while one of the repertoire's screens is
  showing (overview, builder, study), limited to opponent-to-move positions above the target.
  A 429 from either pauses both for 60 s (kept across launches) and slows the coverage pace for
  good; re-login on 401. Never fetch every position of a PGN. Cached stats never expire for now.
  Offline coverage tables: `core/AGENTS.md`.

## Building and committing
- Rust: `core/scripts/check.sh` before committing (fmt, clippy -D warnings, tests, wasm32,
  cargo deny).
- Apple: `core/scripts/build-apple.sh` after changing Rust code, then xcodebuild
  (`apple/AGENTS.md`).
- Android and desktop: `core/scripts/build-android.sh` after changing the FFI, then Gradle
  (`android/AGENTS.md`).
- A hook (`.claude/hooks/check-before-commit.sh`) runs the checks a commit needs before every
  `git commit` and blocks it on failure: check.sh for `core/`, build-apple.sh for `core/orbt-ffi/`
  or Cargo.lock (the committed bindings must be up to date), the simulator build for `apple/` or
  the FFI, build-android.sh and the JVM tests for `android/` or the FFI. A blocked commit is fixed,
  not bypassed.
- A release: raise `Version.xcconfig`, merge, tag `v<MARKETING_VERSION>` (`v1.0.1-beta.1` is a
  pre-release; the workflow stops on a tag that differs), publish the draft.
