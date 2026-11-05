# ORBT Chess (Opening Repertoire Builder & Trainer)

Said "orbit"; website orbtchess.org. Users see "ORBT Chess"; code, folders and identifiers say
ORBT (`org.orbtchess.orbt`). Open-source (AGPL-3.0), subscription-free alternative to Chessbook.
A Rust core (`core/`) shared by the Apple app (`apple/`, SwiftUI) and the Android, Windows and
Linux app (`android/`, Compose Multiplatform). Each has its own `AGENTS.md`.

## How the owner uses the app (every feature serves this)
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

Non-goals for now: auto gap filling, online game review, daily tasks, plans in a position,
model games.

## Decisions
- When an established system already solves something (Anki for training, Chessbook for
  practice, lichess for analysis), port its behaviour from its source code rather than invent
  rules, and list every deviation for the owner to approve.
- Rules live in `core/orbt-core`, with Rust tests; the apps never re-implement them. A new rule
  or query goes into the core and out through `orbt-ffi`. The core takes time as arguments and
  returns what to do (saves, fetches); the apps run the IO and timers.
- A repertoire is a PGN in the app's folder, saved on every edit. Settings and training state
  live in a sidecar `<Name>.otrep.json`, never in the PGN; the review log is
  `<Name>.otlog.jsonl` (append-only, Anki revlog entries). Several games from the standard
  position are merged into one; games from another start are kept verbatim.
- Transpositions: each position's lines are stored once; other move orders reaching it are
  leaves pointing at it (`transpositionTarget`). Chessbook exports, which repeat subtrees, are
  rewritten compactly after opening.
- Coverage: an opponent reply is required when its reach is ≥ 1/N (the repertoire's target)
  and its position has enough games; README.md "How coverage is computed" has the model.
- Training is a port of Anki's scheduler: follow Anki's code, not invented rules. Chess
  additions stay minimal and are listed in `training/study.rs`; every difference from Anki or
  lichess goes in `core/DEVIATIONS.md`. Ported files keep their AGPL header naming the source.
  The UI follows Anki (deck list → overview → options), says "moves", never "cards", and shows
  Anki's card-count groups, not percentages. Grading is Again/Good only.
- The analysis board's tree is never saved: back to Build it becomes the builder's draft; back
  to Study it is dropped and the card counts as Again.
- Lichess allows about 20 explorer requests a minute per user (measured): expect 429s, pause
  60 s on one, and never fetch every position of a PGN. The background coverage check runs only
  while one of the repertoire's screens is showing.

## UI
- Use the platform's own components and let them decide: no overrides of system styling or
  layout (forced title modes, hand-set widths or sheet frames, restyled toolbars). If an
  override seems needed, the API is being used wrong. Containers supply titles; a new screen
  copies the screen it mirrors. A screen's actions are the same system button: the most likely
  one prominent (`.borderedProminent`), the others `.bordered`.
- The iOS layout is the base; Android follows it with Material 3 Expressive components and
  look. Fixes found on Android stay Android-only.
- Moving or removing an existing control needs the owner's OK.
- Colors are meanings, never hues (`Design/COLORS.md`; read it before any color change). The
  commit hook blocks hue names in the UI outside the palette files.

## Commands
- Rust: `core/scripts/check.sh` (fmt, clippy, tests, wasm32, cargo-deny). One test file:
  `cargo test -p orbt-core --test <name>` in `core/`.
- Apple: `core/scripts/build-apple.sh` after any Rust change, then
  `xcodebuild -project apple/ORBT.xcodeproj -scheme ORBT -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' build`.
- Android and desktop: `core/scripts/build-android.sh --debug` after any FFI change, then in
  `android/`: `./gradlew :core:jvmTest :app:desktopTest` (one class: `--tests '<Class>'`),
  `:androidApp:assembleDebug`, `:app:run`.

## Gotchas
- A `.claude/hooks` hook runs the checks a commit needs before every `git commit` and blocks it
  on failure. Fix the failure; never bypass it. It sees unstaged files only when the same
  command runs `git add`.
- Built core libraries (the xcframework, Android's and the host's) are not committed. The commit
  hook copies or rebuilds them when they don't match the sources; by hand, `build-apple.sh` and
  `build-android.sh --debug` (an old host library fails the JVM tests with `UnsatisfiedLinkError`).
- Generated bindings (`opening_core.swift`, `opening_core.kt`) are committed and never edited by
  hand.
- `testData/` (ignored) holds personal repertoires for manual tests. Never commit one.
- The version and build number live only in `Version.xcconfig` (its comments say how they move).
