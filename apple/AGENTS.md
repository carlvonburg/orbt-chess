# The Apple app (iPhone, iPad, Mac)

One multiplatform target, not Catalyst. The rules live in the Rust core (root `AGENTS.md`).

## Layout
- `ORBT.xcodeproj`; `ORBT/` is the app target (folder-synced group, new files are picked up
  automatically): `Engine/` (the engine service, the full net download), `Lichess/`,
  `Storage/`, `UI/`. `Config/` holds the Info.plist and the iOS and macOS entitlements (same
  iCloud container; macOS sandboxed).
- `ORBTTests/` — Swift Testing target hosted in the app (folder-synced): conflict merging and
  file presenters over a temporary folder.
- `UI/Components/Platform.swift` — the few iOS-only modifiers and what macOS uses instead.
- `UI/Components/Palette.swift` — every color: the `Theme` (one per app color, in the
  environment) and the roles views use (`ThemeColor`), the app color setting (`AppColor`) and
  the board's colors. Views use roles, never a hue by name.
- `OpeningCoreRust/` — Swift package over the Rust core: the xcframework (built, not
  committed), the generated `opening_core.swift` (never edit by hand) and `Additions.swift`
  (hand-written conveniences: names, conformances; no rules).

## The Swift side
It does IO and platform work only: files (NSFileCoordinator, iCloud conflict versions, handed
to the core to merge), URLSession for the core's requests, Keychain and web sign-in, the
SwiftData stats cache, timers (save debounce from the core's `Changes`, the drill's step
clock), UserDefaults and the UI. Models (`RepertoireDocument`, `BuilderModel`, `DrillModel`,
`StatisticsModel`, `ExplorerService`) are thin `@Observable` wrappers that forward to the core
and re-read it when its revision changes.

- App code is MainActor by default (`SWIFT_DEFAULT_ACTOR_ISOLATION`). Core objects are called
  from the main actor; foreign callbacks (`DocumentListener`, `ExplorerListener`) hop to it.
  File IO and heavy core calls (opening, saving, remote merges) run off the main actor: a
  document's `Writer` runs them one at a time, and each coordinated access passes that file's
  presenter. `ExplorerCacheStore` is thread-agnostic (the core calls it from any thread).
- iCloud conflict versions are merged, then removed: the PGN into the document, the sidecar
  with `mergeSidecarData` and the review log with `mergeRevlogData`.

## Colors (`Design/COLORS.md`, roles in `UI/Components/Palette.swift`)
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
row (`backgroundProminence == .increased`) they turn white. Anything that asks the user to act
is colored; a color is removed only where nothing gets less clear. Prefer system colors and
semantic styles (Apple themes them); custom values only as asset color sets with Dark and High
Contrast variants. The board has its own theme (slate tinted toward the app color); its arrows,
hint and ✓ (Multicolor: a green ✓) are one ink (the app color 55% toward black, told apart by
width, opacity and dashes), its highlights the app color, the ✕ `.wrong` and the engine's lines
graphite. The commit hook blocks hue names in `UI/` outside `Palette.swift`.

## App icon
The Icon Composer document `ORBT/AppIcon.icon` is the icon of every platform: a knight on a
stack of flashcards on a 2×2 board (a partial ring was dropped: it reads as the system's
download progress). Keep it Icon Composer's: the `Assets/` SVGs are plain white shapes, and
their colors are fills in `icon.json` (`fill-specializations` for dark; the board's dark
squares are the document fill); glass, specular, shadows, tinted and clear come from the
system, never baked into the SVGs. An open stroked path gets its chord filled, so draw strokes
as filled outlines. Check every appearance with Icon Composer's renderer:
`"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" apple/ORBT/AppIcon.icon --export-image --output-file out.png --platform iOS --rendition Default --width 1024 --height 1024 --scale 1`
(renditions Default, Dark, TintedLight, TintedDark, ClearLight, ClearDark), then update the
`Design/` references and the App icon section of `Design/COLORS.md`.

Change everything derived from it with the icon: Android's adaptive icon and the desktop's
icons and installer pictures (`android/AGENTS.md`); the welcome screen's
`ORBT/Assets.xcassets/AppIconImage.imageset` is ictool's Default rendition at 360 px (the icon
as people know it, in dark mode too); the website's icons (`website/README.md`).

## Building
- `core/scripts/build-apple.sh` after changing Rust code and once after cloning.
- `xcodebuild -project apple/ORBT.xcodeproj -scheme ORBT -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' build`
  (iPad: `name=iPad Pro 13-inch (M5)`; Mac: `-destination 'platform=macOS'`, which needs a Mac
  development profile for the iCloud entitlement, or `CODE_SIGNING_ALLOWED=NO` to compile only).
- `Version.xcconfig` (repo root) is included by `Config/ORBT.xcconfig`.
- A Release build (Archive) runs `scripts/check-release.sh`: the keys in `Secrets.xcconfig`, and
  the framework's `OpeningCoreFFI.sources` must be `core-fingerprint.sh` now.
