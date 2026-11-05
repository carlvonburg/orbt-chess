---
name: release
description: Cut a release of ORBT Chess for every store. Raises the version, checks the release inputs, tags it so GitHub builds the Windows and Linux packages.
disable-model-invocation: true
---
1. The owner merges into main; never merge or push without being asked in this session.
2. Raise `Version.xcconfig`: `MARKETING_VERSION` for a new version, and always
   `CURRENT_PROJECT_VERSION` by one (one counter for every store, one more per upload, never back).
3. Apple: Archive in Xcode. `apple/scripts/check-release.sh` runs first and needs
   `apple/Config/Secrets.xcconfig` and an xcframework built by `core/scripts/build-apple.sh` from
   the current sources.
4. Android: `core/scripts/build-android.sh` (release, no `--debug`), then
   `./gradlew :androidApp:bundleRelease` in `android/`. `checkReleaseInputs` needs the Dropbox key
   and the upload key (`keystore.properties`).
5. Windows and Linux: tag `v<MARKETING_VERSION>` on main (`v1.0.1-beta.1` is a pre-release) and
   push the tag. `.github/workflows/release.yml` checks the tag matches `Version.xcconfig` and the
   sync secrets, then makes a draft release with the MSI, the .deb, the Store's MSIX and their
   SHA-256 sums. Publish the draft.
6. Store listings: `Design/AppStore/`, `Design/PlayStore/`, `Design/MicrosoftStore/`
   (`metadata.md` in each).

Testing the MSIX locally on Windows: `./gradlew :app:packageMsix`, then
`android/app/msix/sign-for-testing.ps1` signs a copy with a self-signed certificate (never
committed) for `Add-AppxPackage`. The MSIX's identity is Partner Center's (`orbt.msix*` in
`android/gradle.properties`); its version is `<major>.<minor>.<build>.0`.
