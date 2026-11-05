# The Android, Windows and Linux app

- Ported from the Swift side, screen by screen: compare with the Apple app's code and the
  screenshots in `website/public/assets/screens/`. Stock Material 3 (Expressive) components,
  never restyled to look like iOS; custom drawing only where no component exists (board, Anki
  bars, charts).
- `app/` is shared by Android and the desktop (`commonMain`, `androidMain`, `desktopMain`);
  `androidApp/` holds only what needs the Android app itself. UI rules: `app/.../ui/AGENTS.md`.
- The core's `.so`s (`androidApp/src/main/jniLibs/`) and the host library are built by
  `core/scripts/build-android.sh`, never committed.
- Dropbox's app key is the Gradle property `orbt.dropboxAppKey` (or `local.properties`), never
  committed. Release variants check it and the upload key first (`checkReleaseInputs`).
- The desktop's Google Drive client secret ships in the app on purpose: Google's "Desktop app"
  clients need one but can't keep it, so it is not a secret.
- Desktop storage: the program installs to AppData\Local\ORBT Chess App and its data lives in
  AppData\Local\ORBT Chess. jpackage's per-user MSI can only install one folder deep (deeper
  fails WiX's ICE64 on CI). In the MSIX, what the app creates in `APPDATA` goes into the
  package's storage, but `~/ORBT Chess` is never redirected.
- Windows and Linux packages are built on GitHub's machines (`.github/workflows/release.yml`),
  each on its own OS; see the `release` skill.
