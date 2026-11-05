# ORBT Chess

[![License: AGPL-3.0-or-later](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/carlvonburg/orbt-chess?include_prereleases)](https://github.com/carlvonburg/orbt-chess/releases)

ORBT (said "orbit": Opening Repertoire Builder & Trainer) is a free, open-source opening
repertoire trainer for iPhone, iPad, Mac, Android, Windows and Linux: no subscription, no ads,
no account. [orbtchess.org](https://orbtchess.org)

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="website/public/assets/screens/ipad-build-dark.webp">
    <img src="website/public/assets/screens/ipad-build-light.webp" alt="Building a repertoire on iPad: the board, the moves with their statistics, and the gaps" width="560">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="website/public/assets/screens/iphone-study-dark.webp">
    <img src="website/public/assets/screens/iphone-study-light.webp" alt="Studying on iPhone" width="194">
  </picture>
</p>

## Download
Every platform's download, store link and requirements are on
[orbtchess.org/download](https://orbtchess.org/download/). The Windows installer (.msi), the Linux
package (.deb), their SHA-256 sums and the source of each version are on
[GitHub Releases](https://github.com/carlvonburg/orbt-chess/releases).

## Features
- **Build.** Every move shows how often it's played, how it scores and the engine's
  evaluation, from the Lichess opening explorer. Enter the lines from a book or video, or pick
  moves with the numbers. Transpositions are recognised: a position's lines are stored once.
- **Find the gaps.** Set a target such as "every move played once in 500 games", and ORBT
  lists each opponent move above it that you have no answer for, how often you'd meet it, and
  how complete each line is. Prepare against Lichess blitz or rapid players by rating, or
  over-the-board classical games; their statistics download once, then coverage works offline.
- **Analyse.** One tap opens the position on an analysis board with the moves that led there:
  Lichess's cloud evaluation when there is one, otherwise Stockfish 19 on the device. Bring a
  line back to the repertoire in one tap.
- **Study.** Each position where it's your move is a card, scheduled with Anki's scheduler
  (learning steps, FSRS, daily limits). Study everything that's due, or drill one branch.
  Works offline.
- **Your files.** A repertoire is a plain PGN file, saved on every edit. Import any PGN.

## Where your repertoires live
There is no ORBT server: each repertoire is a PGN file next to its training state
(`<Name>.otrep.json`) and review log (`<Name>.otlog.jsonl`), synced by a service you choose in
Settings › Sync.

| Platform | Repertoires | Sync |
|---|---|---|
| iPhone, iPad, Mac | iCloud Drive (Files › ORBT Chess) | iCloud Drive, or Dropbox or Google Drive |
| Android | the app's own storage | Dropbox or Google Drive |
| Windows, Linux | `ORBT Chess` in your Documents folder | Dropbox or Google Drive |

One service syncs at a time. Dropbox keeps the files in its `Apps/ORBT Chess` folder; Google
Drive gives ORBT access only to the files it created. Phones use the services' APIs rather than
their apps because neither syncs a folder on a phone.

## How coverage is computed
For each position, *reach* is the probability of getting there: your own moves count as
1, and each opponent move multiplies by its share of games in the explorer. An opponent
reply is *required* when its reach is at least 1/N (your target) and the position has
enough games. A gap is a required reply you have no line for, or a position where it's
your move and you have none. Completion is the frequency-weighted share of required
replies that are covered, recursively.

Results are cached per node. Editing a line only recomputes that line's subtree and its
ancestors. Statistics are cached by position (FEN without move counters), so each position
is fetched once, and the offline coverage tables answer the common positions without a
request.

## Layout
- `core/`: the Rust core shared by every app (chess, PGN, repertoire, coverage, training,
  sync, the analysis board and the engine). `orbt-core` has no IO or platform APIs;
  `orbt-ffi` exposes it to Swift and Kotlin with UniFFI.
- `apple/`: the iPhone, iPad and Mac app (SwiftUI, one multiplatform target).
- `android/`: the Android, Windows and Linux app (Compose Multiplatform).
- `website/`: orbtchess.org. `tools/coverage-tables/`: builds the offline coverage tables.
- `Design/`: the app icon and the color system (`COLORS.md`).

Native apps only, no web app: a browser app would need a server of ours to keep a Google Drive
sign-in, and couldn't run Stockfish natively or open a local folder in every browser.
`AGENTS.md` (one at the root and one per app) holds the rules for contributors and coding
agents.

## Building
Requires rustup (`brew install rustup`); the pinned toolchain in `core/rust-toolchain.toml`
installs itself on first use. Before committing Rust changes, `core/scripts/check.sh` runs fmt,
clippy, the tests, a wasm32 build and cargo-deny (`cargo install --locked cargo-deny` once).

**iPhone, iPad and Mac** (Xcode 26):
```
core/scripts/build-apple.sh
xcodebuild -project apple/ORBT.xcodeproj -scheme ORBT -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
`build-apple.sh` builds the core for iOS, the iOS simulator and macOS and regenerates the
Swift bindings; run it again after changing Rust code. For the Mac, use
`-destination 'platform=macOS'`, which needs a development profile for the iCloud
entitlement, or add `CODE_SIGNING_ALLOWED=NO` to compile only.

**Android, Windows and Linux** (JDK 17; the Android NDK from Android Studio's SDK Manager):
```
core/scripts/build-android.sh --debug
cd android
./gradlew :androidApp:assembleDebug   # the Android app
./gradlew :app:run                    # the desktop app
./gradlew :core:jvmTest :app:desktopTest
```
Windows and Linux packages are built on their own OS (`.github/workflows/release.yml`).
Dropbox and Google Drive need app keys of your own (`apple/Config/Secrets.xcconfig`, the
Gradle property `orbt.dropboxAppKey`); without them the apps build with those services off.

Once per clone, `git config core.hooksPath core/scripts/git-hooks` turns on hooks that keep the
built core (not committed) in step when a pull, merge, rebase or branch switch changes it.

## Contributing
Bug reports and ideas are welcome in [GitHub issues](https://github.com/carlvonburg/orbt-chess/issues).
Pull requests aren't accepted for now, so that the app-store builds stay under one copyright
holder. For security problems, see [SECURITY.md](SECURITY.md).

## License
AGPL-3.0-or-later (`LICENSE`). ORBT builds on:
- [Anki](https://github.com/ankitects/anki)'s scheduler, ported to Rust (AGPL-3.0, Ankitects
  Pty Ltd and contributors), and [fsrs-rs](https://github.com/open-spaced-repetition/fsrs-rs)
  (BSD-3-Clause, Open Spaced Repetition)
- [Stockfish](https://stockfishchess.org) (GPL-3.0), built from lichess's
  [multistockfish](https://github.com/lichess-org/dart-multistockfish)
- [shakmaty](https://github.com/niklasf/shakmaty) for the chess rules (GPL-3.0-or-later)
- the "cburnett" piece set (GPL-2.0-or-later), via Lichess
- [Lichess](https://lichess.org)'s opening explorer, cloud evaluations and CC0 game database
- [Lumbra's Gigabase](https://lumbrasgigabase.com) for the over-the-board statistics (CC BY-NC
  4.0; ORBT reduces its games since 2000 to the move counts of its coverage tables)

ORBT is an independent project, not affiliated with Lichess, Anki or Stockfish.
