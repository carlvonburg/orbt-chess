# The Android, Windows and Linux app

One Compose Multiplatform app (`docs/PLATFORMS.md`), ported from the Apple app: the iOS layout
is the base. The rules live in the Rust core (root `AGENTS.md`).

## Layout
AGP 9's layout for Kotlin Multiplatform: `core/` and `app/` are KMP libraries
(`com.android.kotlin.multiplatform.library`), `androidApp/` the Android app.
- `core/` holds the generated `opening_core.kt` (committed, never edited by hand) and
  `jvmTest/SmokeTest.kt`, the parallel of the Swift smoke test.
- `app/` is the shared app and the desktop app (`android`, `jvm("desktop")`; `:app:run`):
  `commonMain` holds the UI and the platform layer ported from the Swift side, by package —
  - `platform`: HTTP for the core's requests, `AppFolders`, `Settings`, `SecretStore`.
  - `storage`: library, documents, saves. The desktop's `FolderWatcher` follows changes made to
    `ORBT Chess` in the user's documents outside the app, and its saves overwrite in place. The
    app's own data is in the per-user app data folder, on Windows AppData\Local\ORBT Chess, apart
    from the program in AppData\Local\ORBT Chess App: uninstalling deletes that folder whole, and
    jpackage's per-user MSI can only install one folder deep, since deeper fails WiX's ICE64 on CI.
  - `explorer`: queue, SQLite stats cache, coverage tables.
  - `engine`; `lichess` (PKCE: Custom Tabs on Android, a loopback redirect on the desktop);
    `sync` (`SyncService` runs the core's `RepertoireSync` with Dropbox or Google Drive; the
    sign-ins are Android's).

  Wired by `AppModel.kt`; Android's and the desktop's own code in `androidMain`/`desktopMain`;
  tests in `desktopTest`. Colors by name only in `ui/theme` (`Design/COLORS.md`; the commit hook
  checks it).
- `androidApp/` (`com.android.application`, AGP's built-in Kotlin) holds what needs the app
  itself: the activities and the manifest, `androidPlatform` (Keystore secrets, Custom Tabs for
  sign-ins and pages, Play services' Google Drive sign-in, Dropbox), the core's `.so`s in
  `src/main/jniLibs/` (built, not committed), the version and signing.
- `PLAY.md`: what is sent where (Data safety).
- Dropbox's app key comes from the Gradle property `orbt.dropboxAppKey` (or `local.properties`),
  read by `androidApp/build.gradle.kts`, never committed.
- `build.gradle.kts` reads the repo's `Version.xcconfig`: the Android app's
  versionName/versionCode, the desktop's packageVersion.

## Icons (derived from `apple/ORBT/AppIcon.icon`, see `apple/AGENTS.md`)
Android's adaptive icon is derived by hand: vector drawables in
`androidApp/src/main/res/drawable/ic_launcher_{background,foreground,monochrome}.xml` (the board;
the cards and knight in the icon's 1024 units, its square the visible 72dp; the themed icon's
one-color layer), also the splash's icon. The desktop's `app/icons/orbt.ico` and
`app/src/desktopMain/resources/orbt-icon.png` are rendered from `Design/AppIcon-light.svg` (how:
`app/build.gradle.kts`), the MSI's pictures `app/icons/installer-*.bmp` from the .ico
(`installer-bitmaps.ps1`; `installer-msi.ps1` puts them in the MSI after `packageMsi`) and the
MSIX's tiles `app/msix/Assets/*.png` from `orbt.ico` (`app/msix/assets.ps1`).

## Building and testing
- `core/scripts/build-android.sh [--debug]` after changing the FFI (needs the Android NDK from
  Android Studio's SDK Manager), then `./gradlew :core:jvmTest` here (`:androidApp:assembleDebug`
  builds the APK). It also builds the host's library, which `:app:run` and the packaged desktop
  app load from the app's resources (`copyHostLibrary`).
- Before committing: `:core:jvmTest`, `:app:desktopTest`, and the Android app's Kotlin compile
  (the commit hook runs them).
- Android's release variants depend on `checkReleaseInputs`: the Dropbox key, the upload key, and
  `androidApp/jniLibs.sources`, written by a release build-android.sh.

## Windows and Linux packages
Built by `.github/workflows/release.yml` on GitHub's machines (a package is built on its own OS).
A version tag (`v1.0.0`; `v1.0.1-beta.1` is a pre-release) makes a draft release with the MSI,
the .deb and their SHA-256 sums, after checking the sync secrets (repository secrets); pull
requests build and test both. The Windows job also builds the Microsoft Store's MSIX
(`:app:packageMsix`, `app/msix/`: `pack.ps1` packs Compose's app image with the Windows SDK's
makepri and makeappx from `AppxManifest.xml`; unsigned, the Store signs it), attached next to the
MSI. Its identity is Partner Center's, in `gradle.properties` (`orbt.msix*`); its version is
`<major>.<minor>.<build>.0` (the Store's last part is 0). Locally on Windows:
`./gradlew :app:packageMsix`, then `app/msix/sign-for-testing.ps1` signs a copy with a
self-signed certificate (never committed) for `Add-AppxPackage`. In the package, what the app
creates in `APPDATA` goes into the package's storage (removed with it), but an
`APPDATA\ORBT Chess` an MSI install made is written in place, and `~/ORBT Chess` is never
redirected.
