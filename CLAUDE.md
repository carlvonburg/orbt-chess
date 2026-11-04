# ORBT Chess (ORBT: Opening Repertoire Builder & Trainer)

Said "orbit"; website orbtchess.org. Identifiers use the domain: bundle ID `org.orbtchess.orbt`,
iCloud container `iCloud.org.orbtchess.orbt` (the Files folder is "ORBT Chess").
Users see "ORBT Chess" (display and bundle name); code, folders and identifiers say ORBT.

Open-source (AGPL-3.0), subscription-free alternative to Chessbook for iPhone, iPad and Mac.
A Rust core shared by every platform, with a SwiftUI app (iOS/iPadOS 26 and native macOS 26,
Liquid Glass) on top. Repertoires are PGN files in iCloud Drive (or synced with Dropbox or Google Drive); opponent
statistics come from the Lichess opening explorer. Platforms and sync: `docs/PLATFORMS.md`.

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
  created there, or imported (copied in) from Files.
  Every edit is saved to the PGN immediately. Settings and training state live in a
  sidecar `<Name>.otrep.json`, never in the PGN; the review log is `<Name>.otlog.jsonl`
  (append-only, one Anki revlog entry per line).
- Each repertoire chooses its coverage database (masters, or Lichess speeds + rating
  buckets) and its coverage target ("cover moves seen once in N games").

Non-goals for now: auto gap filling, online game review, daily tasks, plans in a
position, model games.

## Layout
One folder per platform around a shared core (Android, Windows and Linux would be one Compose app in `android/`).
- `core/` — the Rust core (Cargo workspace), the only place for domain rules:
  - `orbt-core/` — pure Rust, no IO, no async, no OS APIs; must keep building for wasm32. Modules:
    `chess` (shakmaty), `pgn` (our parser and byte-exact writer), `repertoire` (tree,
    transpositions, merge), `explorer` (stats, sans-IO request queue, cache, offline coverage tables and their
    manifest), `coverage`,
    `training` (`anki/` is Anki's scheduler; trainer, study session, line run), `statistics`
    (Anki's graphs, scoping, chess stats), `formats` (sidecar and revlog), `document` (the open repertoire: edits, undo, save hints, remote merges,
    outline/search), `builder`, `drill` (state machines behind the two main screens), `oauth`
    (PKCE and the redirect back, for every sign-in), `lichess` (sign-in requests, analysis
    URL, cloud evals), `engine` (UCI, which evaluation to show), `analysis`
    (the analysis board's tree), `sync` (the folder synced with Dropbox or Google Drive: a
    sans-IO loop like the explorer queue, each provider a small `Provider` of requests and answers;
    Dropbox's sign-in requests too, and signing out revokes on the server).
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
  - Tests: `orbt-core/tests/*.rs` state the rules; `orbt-core/tests/snapshot_*.rs` are insta
    snapshot tests over the inputs in `orbt-core/tests/data/`, including every line of lichess's
    opening names as one large repertoire (`data/repertoires/`, CC0) (snapshots in
    `tests/snapshots/`; after an intended change, `cargo insta review` or
    `INSTA_UPDATE=always cargo test`, then read the diff). Never commit a personal repertoire. `DEVIATIONS.md` lists where the core
    differs from Anki/lichess.
  - `rust-toolchain.toml` pins the Rust version, components and targets; `deny.toml` configures
    cargo-deny (licenses compatible with AGPL-3.0-or-later, RustSec advisories, bans, sources).
  - `scripts/check.sh` (fmt, clippy -D warnings, tests, wasm32 check, cargo deny),
    `scripts/build-apple.sh` (also runs `scripts/acknowledgements.py`: the linked crates and
    their license texts in the app's `UI/Settings/Acknowledgements.json`), `scripts/git-hooks/` (git hooks, on with
    `git config core.hooksPath core/scripts/git-hooks`: rebuild the xcframework when a merge,
    pull, rebase or branch switch changes the core, so it never lags the committed bindings;
    a new worktree copies another worktree's xcframework when `scripts/core-fingerprint.sh`
    matches the one `build-apple.sh` recorded, instead of building), `scripts/build-android.sh`
    (Android's `.so`s with the NDK, the host library for JVM tests, the Kotlin bindings).
  - `fuzz/` — cargo-fuzz targets for what the app reads (PGN, sidecar, review log, explorer
    answers, engine output, storage provider answers), outside the workspace; `fuzz/run.sh [seconds]` runs them all (nightly).
    The core must not panic or recurse per ply on any input: the app calls it on small
    stacks, and a panic or overflow in a non-throwing call crashes it on every launch.
- `apple/` — the iPhone, iPad and Mac app (one multiplatform target, not Catalyst):
  - `ORBT.xcodeproj`; `ORBT/` is the app target (folder-synced group, new
    files are picked up automatically): `Engine/` (the engine service, the full net download), `Lichess/`, `Storage/`, `UI/`. `Config/` holds the
    Info.plist and the iOS and macOS entitlements (same iCloud container; macOS sandboxed).
  - The Swift side does IO and platform work only: files (NSFileCoordinator, iCloud conflict
    versions, handed to the core to merge), URLSession for the core's requests, Keychain and
    web sign-in, the SwiftData stats cache, timers (save debounce from the core's `Changes`, the
    drill's step clock), UserDefaults and the UI. Models (`RepertoireDocument`, `BuilderModel`,
    `DrillModel`, `StatisticsModel`, `ExplorerService`) are thin `@Observable` wrappers that
    forward to the core and re-read it when its revision changes.
  - `ORBTTests/` — Swift Testing target hosted in the app (folder-synced): conflict
    merging and file presenters over a temporary folder.
  - `UI/Components/Platform.swift` — the few iOS-only modifiers and what macOS uses instead.
  - `UI/Components/Palette.swift` — every color: the `Theme` (one per app color, in the
    environment) and the roles views use (`ThemeColor`), the app color setting (`AppColor`) and
    the board's colors. Views use roles, never a hue by name.
  - `OpeningCoreRust/` — Swift package over the Rust core: the xcframework (built, not
    committed), the generated `opening_core.swift` (never edit by hand) and `Additions.swift`
    (hand-written conveniences: names, conformances; no rules).
- `android/` — Gradle project for Android, Windows and Linux (Compose Multiplatform,
  `docs/PLATFORMS.md`), in AGP 9's layout for Kotlin Multiplatform: `core/`
  and `app/` are KMP libraries (`com.android.kotlin.multiplatform.library`), `androidApp/` the
  Android app. `core/` holds the generated `opening_core.kt` (committed, never edited by hand)
  and `jvmTest/SmokeTest.kt`, the parallel of the Swift smoke test. `app/` is the shared app
  and the desktop app (`android`, `jvm("desktop")`; `:app:run`): `commonMain` holds the UI and the
  platform layer ported from the Swift side, by package — `platform` (HTTP for the core's
  requests, `AppFolders`, `Settings`, `SecretStore`), `storage` (library, documents, saves; the desktop's `FolderWatcher` follows changes made to
  `ORBT Chess` in the user's documents outside the app, and its saves overwrite in place; the app's
  own data in the per-user app data folder, on Windows AppData\Local\ORBT Chess, apart from the
  program in AppData\Local\ORBT Chess App: uninstalling deletes that folder whole, and jpackage's
  per-user MSI can only install one folder deep, since deeper fails WiX's ICE64 on CI),
  `explorer` (queue, SQLite stats cache, coverage tables), `engine`, `lichess` (PKCE: Custom
  Tabs on Android, a loopback redirect on the desktop), `sync` (`SyncService` runs the core's
  `RepertoireSync` with Dropbox or Google Drive; the sign-ins are Android's) — wired by
  `AppModel.kt`; Android's and the desktop's own code in `androidMain`/`desktopMain`; tests in
  `desktopTest`. `androidApp/` (`com.android.application`, AGP's built-in Kotlin) holds what
  needs the app itself: the activities and the manifest, `androidPlatform` (Keystore secrets,
  Custom Tabs for sign-ins and pages, Play services' Google Drive sign-in, Dropbox), the core's
  `.so`s in `src/main/jniLibs/` (built, not committed), the version and signing.
  `android/PLAY.md`: what is sent where (Data safety). Dropbox's app key comes from
  the Gradle property `orbt.dropboxAppKey` (or `local.properties`), read by
  `androidApp/build.gradle.kts`, never committed.
- `Design/` — `AppIcon-*.svg`, flat references of the app icon; `COLORS.md`, how the app uses
  color (read before any color change).
- The app icon is the Icon Composer document `apple/ORBT/AppIcon.icon` (one for every platform):
  a knight on a stack of flashcards on a 2×2 board (a partial ring
  was dropped: it reads as the system's download progress). Keep it Icon Composer's: the `Assets/` SVGs are
  plain white shapes, and their colors are fills in `icon.json` (`fill-specializations` for dark;
  the board's dark squares are the document fill); glass, specular, shadows, tinted and clear
  come from the system, never baked into the SVGs. An open stroked path gets its chord filled, so
  draw strokes as filled outlines. Check every appearance with Icon Composer's renderer:
  `"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" apple/ORBT/AppIcon.icon --export-image --output-file out.png --platform iOS --rendition Default --width 1024 --height 1024 --scale 1`
  (renditions Default, Dark, TintedLight, TintedDark, ClearLight, ClearDark), then update the
  `Design/` references and the App icon section of `COLORS.md`.
  Android's adaptive icon is derived from it by hand: vector drawables in
  `android/androidApp/src/main/res/drawable/ic_launcher_{background,foreground,monochrome}.xml`
  (the board; the cards and knight in the icon's 1024 units, its square the visible 72dp; the
  themed icon's one-color layer), also the splash's icon; the desktop's `android/app/icons/orbt.ico`
  and `app/src/desktopMain/resources/orbt-icon.png` are rendered from `Design/AppIcon-light.svg`
  (how: `android/app/build.gradle.kts`), the MSI's pictures `android/app/icons/installer-*.bmp`
  from the .ico (`installer-bitmaps.ps1`; `installer-msi.ps1` puts them in the MSI after
  `packageMsi`) and the MSIX's tiles `android/app/msix/Assets/*.png` from `orbt.ico`
  (`android/app/msix/assets.ps1`); the welcome screen's `apple/ORBT/Assets.xcassets/AppIconImage.imageset`
  is ictool's Default rendition at 360 px (the icon as people know it, in dark mode too). Change them with the icon.
- `Version.xcconfig` — the version and build number of every platform, nowhere else: Xcode
  includes it (`apple/Config/ORBT.xcconfig`), Gradle reads it (`android/build.gradle.kts`: the
  Android app's versionName/versionCode, the desktop's packageVersion). One build counter for
  every store: one more per upload, never back.
- `testData/` — ignored by git: personal repertoires for testing by hand and timing
  (`ORBT_LARGE_PGN`). Never committed.
- `docs/PLATFORMS.md` — native only: Compose for Android, Windows and Linux; storage and the Google Drive and Dropbox connectors; why no web app.

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
copyright header naming the source files, in Rust as before in Swift (see `training/anki/*.rs`,
`statistics/mod.rs`); differences from the source go in `core/DEVIATIONS.md`.
The UI follows Anki's deck list → deck overview → deck options, and says "moves", never
"cards". Progress uses Anki's card-count groups (learning, young, mature), not a percentage.
Study All runs repertoires one after another (Anki would mix a parent deck's reviews).

## Analysis board and engine (see `core/orbt-core/src/engine`, `analysis`; `core/orbt-engine`)
Analysis opens from Build and Study on the position on the board, with its move history. Its
tree is never saved: leaving it for Build puts the path to the selected move on the builder as
its draft (saved moves followed, nothing written, `Builder::set_line`); leaving it for Study
drops it (opening it counted as Again, like browsing). Evaluations: Lichess's cloud eval first;
the local engine waits 600 ms for it, never runs where it is depth ≥ 30 with every line asked
for, and replaces it once deeper (lichess mobile's order). Stockfish 19 runs in-process (iOS
allows no child processes): the light flavour with its 1.1 MB net built in, or the full one
with the 94 MB net downloaded in Settings (checked against its name first: Stockfish exits
the process when a net does not load). Settings: search time, lines (1–5), cloud evals.

## Colors (see `Design/COLORS.md`, roles in `UI/Components/Palette.swift`)
The app color (Settings; Multicolor by default, or blue, indigo or any of the Mac's accent
colors; on the Mac it follows the system accent: when that changes, the app color becomes it,
Multicolor for Multicolor) is the tint of every control, and views take it through `.tint`,
never `Color.accentColor`. Views name meanings, never hues (`ThemeColor`, one set): built,
learned, learning, new, to do, correct, wrong, failure, ahead, inactive. The `Theme` of the app
color resolves them: Multicolor gives each its own system color (building blue, learned and
correct green, learning and wrong red, new blue, to do orange: Anki's colors for studying);
every other app color is tinted like Apple's accented widgets (HIG Widgets, Complications):
the app color for building, learned, correct and to do, the secondary label gray for learning,
the label color for new, red for wrong (purple when the app color is red or pink). Young and
Anki's learning are `.lighter()` shades; each due count has its bar part's color. On a selected
row (`backgroundProminence == .increased`) they turn white. Always with a symbol or text, never
color alone. Anything that asks the user to act is colored; a color is removed only where
nothing gets less clear. Prefer system colors and semantic styles (Apple themes them); custom
values only as asset color sets with Dark and High Contrast variants. The board has its own
theme (slate tinted toward the app color); its arrows, hint and ✓ (Multicolor: a green ✓) are one ink (the app color
55% toward black, told apart by width, opacity and dashes), its highlights the app color, the
✕ `.wrong` and the engine's lines graphite. A new meaning takes a `Palette.swift` role and a row
in `Design/COLORS.md`. The commit hook blocks hue names in `UI/` outside `Palette.swift`.

## Conventions
- Rules belong in `orbt-core`, with Rust tests; Swift never re-implements them. When the app
  needs a new rule or query, add it to the core and expose it through `orbt-ffi`.
- `orbt-core` takes time as arguments (`SchedTiming`, unix ms) and returns what to do
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
- Offline coverage tables (`explorer::table`, OTCB files): a repertoire's coverage database is one
  time control and one rating bin — Blitz or Rapid (Lichess games, Lichess rating) or Classical
  (over-the-board games since 2000 by FIDE rating, Lumbra's Gigabase, CC BY-NC 4.0: credit it, no
  commercial use). Each table holds the positions a repertoire can reach at 1 in 800 (Lichess:
  own moves ≥ 5%, lines stop below 25 games; Classical: every own move, below 10 games),
  downloaded from Cloudflare R2 (`manifest.json`, written by
  `core/scripts/coverage-manifest.py`; always the deepest file) into Application Support/Coverage
  when chosen or when a repertoire using it opens. The stats cache answers from Lichess-fetched
  entries first, then the table (Classical: the table first, Lichess is only its backup); while
  a table downloads nothing is fetched for its database; positions in the table are never
  queued, and queued requests a new table answers are dropped. Positions it lacks still come from the explorer (Classical:
  the masters explorer from 2000, Lichess rapid games one bin up below). The tables are built outside this repo (`data/`, never committed).
- Build:
  1. `core/scripts/build-apple.sh` after changing Rust code and once after cloning (Rust from
     rustup, which installs the pinned toolchain; it builds iOS, iOS simulator and macOS slices
     and regenerates the bindings). `swift test` in `apple/OpeningCoreRust` smoke-tests the
     bindings.
  2. `core/scripts/check.sh` before committing Rust changes (needs
     `cargo install --locked cargo-deny` once).
  3. `xcodebuild -project apple/ORBT.xcodeproj -scheme ORBT -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' build`
     (iPad: `name=iPad Pro 13-inch (M5)`; Mac: `-destination 'platform=macOS'`, which needs a
     Mac development profile for the iCloud entitlement, or `CODE_SIGNING_ALLOWED=NO` to compile
     only).
  4. `core/scripts/build-android.sh [--debug]` after changing the FFI (needs the Android NDK from
     Android Studio's SDK Manager), then `./gradlew :core:jvmTest` in `android/`
     (`:androidApp:assembleDebug` builds the APK). It also builds
     the host's library, which `:app:run` and the packaged desktop app load from the app's
     resources (`copyHostLibrary`), and writes Android's `Acknowledgements.json`.
  5. Windows and Linux packages: `.github/workflows/release.yml` on GitHub's machines (a
     package is built on its own OS). A version tag (`v1.0.0`; `v1.0.1-beta.1` is a pre-release)
     makes a draft release with the MSI, the .deb and their SHA-256 sums; pull requests build and
     test both. The Windows job also builds the Microsoft Store's MSIX (`:app:packageMsix`,
     `android/app/msix/`: `pack.ps1` packs Compose's app image with the Windows SDK's makepri
     and makeappx from `AppxManifest.xml`; unsigned, the Store signs it), attached next to the
     MSI. Its identity is Partner Center's, in `android/gradle.properties` (`orbt.msix*`); its
     version is `<major>.<minor>.<build>.0` (the Store's last part is 0). Locally on Windows:
     `./gradlew :app:packageMsix`, then `app/msix/sign-for-testing.ps1` signs a copy with a
     self-signed certificate (never committed) for `Add-AppxPackage`. In the package, what the app
     creates in `APPDATA` goes into the package's storage (removed with it), but an `APPDATA\ORBT Chess`
     an MSI install made is written in place, and `~/ORBT Chess` is never redirected. The sync keys are repository secrets. A release: raise `Version.xcconfig`, merge,
     tag `v<MARKETING_VERSION>` (the workflow stops on a tag that differs), publish the draft.
  A Claude Code hook (`.claude/hooks/check-before-commit.sh`) runs the ones a commit needs before
  every `git commit` and blocks it on failure: check.sh for `core/`, build-apple.sh for
  `core/orbt-ffi/` or Cargo.lock (the committed bindings must be up to date), the simulator build
  for `apple/` or the FFI, build-android.sh for the FFI (the Kotlin bindings too) and the JVM
  tests (`:core:jvmTest`, `:app:desktopTest`, with the Android app's Kotlin) for `android/` or the FFI. A blocked commit is fixed, not bypassed.
