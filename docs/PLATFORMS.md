# Platforms and sync

Native apps only: SwiftUI on Apple platforms and one Compose Multiplatform app for Android,
Windows and Linux, both over the same Rust core. Repertoires stay plain files with the user's own
storage; there is no ORBT server.

## Why no web app
- Sync without constant sign-ins: Google gives browser-only apps a one-hour token and no refresh
  token, so Drive on the web needs a server for its tokens; native apps get long-lived ones
  (Android through Play Services, desktop through a loopback redirect), and so does Dropbox.
- A web app has to work in every browser or not exist; local folders (File System Access API)
  are Chrome and Edge only.
- Two UIs (SwiftUI, Compose) instead of three, Stockfish native everywhere, and the user's files
  stay with their provider with nothing of ours in between.
- The cost: desktop users install an app instead of opening a website.

`orbt-core` still builds for wasm32 (checked by `core/scripts/check.sh`): cheap to keep, and it
leaves room for a browser demo (data in the browser only, no sync, every browser).

## Two apps over one core
- The Compose app is one Kotlin UI for Android, Windows and Linux over UniFFI's Kotlin bindings
  (`orbt-ffi` is shared; `uniffi-bindgen` generates Kotlin next to Swift; they run on Android and
  the desktop JVM), as Matrix's Element X and Bitwarden ship their Rust cores on Android.
- Its platform layer does what the Swift side does: file IO and saves on the core's `Changes`,
  conflict copies handed to the core, the explorer's `Fetch`es, the stats cache, the Lichess
  sign-in (Custom Tabs on Android, a loopback redirect on the desktop; PKCE is in the core) and
  its token (Keystore; the OS credential store on the desktop), the full net download, the
  drill's timers.
- The core and `orbt-engine` (Stockfish) are built for Android (arm64, x86_64 for the emulator),
  Windows and Linux by `core/scripts/build-android.sh`.

## Windows distribution
- The Microsoft Store, as an MSIX (`android/app/msix/`): Microsoft signs it for free and the
  Store updates it. A full-trust desktop app, so the Lichess sign-in's loopback server works as
  outside the package; `APPDATA` and the Java Preferences registry are redirected into the
  package's storage (gone on uninstall, not shared with an MSI install), `~/ORBT Chess` is not.
- The MSI on GitHub's releases for everyone else, unsigned (SmartScreen warns once).

## Storage on each platform
| Platform | Storage |
|---|---|
| iPhone, iPad, Mac | iCloud Drive, or the device's folder with the Drive or Dropbox connector (one of them) |
| Windows, Linux | `~/ORBT Chess` with the Drive and Dropbox connectors |
| Android | Drive and Dropbox connectors, or a local folder without sync |

- Why connectors on phones: Drive and Dropbox on Android don't sync a folder (files stay online,
  no folder access through the Storage Access Framework), and on iOS their Files providers are
  unreliable for a folder an app keeps open (late changes, online-only files; Obsidian supports
  only iCloud for vaults there).
- Why connectors on computers too: with Drive's `drive.file` (see Connectors) ORBT sees the
  files ORBT created, on every device (access is per Google Cloud project), so the whole "ORBT
  Chess" folder syncs as long as every device writes through ORBT. A file Google Drive for
  desktop uploads is not ORBT's and stays invisible to the other devices; picking files one by
  one is no answer.
- No folder of the user's choosing on computers (it was built, then removed): a folder that
  only computers see (OneDrive, a NAS) never reaches the phones, one inside Dropbox or Drive
  next to the connector syncs twice, and Drive's client hides its files from the phones. The
  desktop still watches `~/ORBT Chess` for files added or edited outside the app.
- Linux has no Google Drive client (rclone, Insync); Dropbox has one.

## Connectors: Google Drive, Dropbox
- Sign in once, no server: Dropbox with PKCE and a refresh token (`token_access_type=offline`);
  Drive through Play services on Android (the system hands out access tokens) and on iOS with
  Google's OAuth for installed apps (PKCE in `ASWebAuthenticationSession`, an iOS client and its
  reversed client id as the redirect scheme, a refresh token; no Google SDK; the Mac the same),
  and on Windows and Linux with a "Desktop app" client and a loopback redirect (its client
  secret ships in the app; Google requires it, it is not secret). So the core's Drive provider
  refreshes tokens too. Tokens in the Keychain, Android's Keystore, the OS credential store.
- Sign-ins last: Dropbox's offline refresh token never expires; Google's lasts until revoked or
  unused for 6 months; Android's Drive tokens come from Play services. A refused token puts sync
  in a signed-out state that Settings › Sync shows with Sign In Again; local edits wait.
- Scopes: Dropbox's App folder (`Apps/ORBT Chess`, like the iCloud folder); Drive's `drive.file`
  (not sensitive: brand verification only, no yearly security assessment). With `drive.file`
  ORBT sees only files it created or the user picked, so files added by other apps are imported
  through the picker. Every client is in one Google Cloud project (access is granted per
  project).
- One of iCloud Drive, Dropbox and Google Drive syncs the repertoires, never two (two would
  each push the same edits): on Apple devices, choosing Dropbox or Google Drive (or off) moves
  them from iCloud Drive's folder to the device's own Documents folder, iCloud Drive keeping its
  copies; choosing iCloud Drive again moves them back. A file in both folders is merged with
  the sync's merge (`sync_merge_files`).
- The sync loop is in `orbt-core` (`sync`), sans-IO like the explorer queue (the core says what
  to download or upload, the platform runs the HTTP): download, merge with the core's merges
  (`RepertoireDoc.remote_pgn`, `remote_sidecar`, `merge_revlogs`, the same code that handles
  iCloud conflict versions), then upload conditionally (Dropbox `rev`, Drive `If-Match` on the
  ETag) and retry on a conflict. The review log stays append-only, so its merge is a union by
  id. Edits made offline upload later; changes from other devices come on open and on focus
  (Dropbox can also long-poll). Each provider is a small HTTP adapter.
