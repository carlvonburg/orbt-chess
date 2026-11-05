---
name: release
description: Cut a release of ORBT Chess for every store. Raises the version, checks the release inputs, tags it so GitHub builds the Windows and Linux packages.
argument-hint: "[version, e.g. 1.0.3 or 1.1.0-beta.1]"
disable-model-invocation: true
---
The version is `$ARGUMENTS`; if it is empty, show the current one from `Version.xcconfig` and ask.

1. Start from main: the main checkout has no uncommitted changes, `git fetch` shows it is not
   behind `origin/main`, and nothing the owner still wants in this release sits on an unmerged
   branch (ask). Stop and ask if any of that fails. Never merge or push without being asked in
   this session.
2. Raise `Version.xcconfig`: `MARKETING_VERSION` to the version, and always
   `CURRENT_PROJECT_VERSION` by one (one counter for every store, one more per upload, never
   back). Commit on main.
3. Apple (the owner): Archive in Xcode, upload to App Store Connect. `apple/scripts/check-release.sh`
   runs first and needs `apple/Config/Secrets.xcconfig` and an xcframework built by
   `core/scripts/build-apple.sh` from the current sources.
4. Android: `core/scripts/build-android.sh` (release, no `--debug`), then
   `./gradlew :androidApp:bundleRelease` in `android/`. `checkReleaseInputs` needs the Dropbox key
   and the upload key (`keystore.properties`). The owner uploads the bundle to the Play Console.
5. Windows and Linux: with the owner's OK, push main, then tag `v<MARKETING_VERSION>`
   (`v1.0.1-beta.1` is a pre-release) and push the tag. The tag can't be taken back once pushed:
   the workflow starts at once. `.github/workflows/release.yml` checks the tag matches
   `Version.xcconfig` and the sync secrets, then makes a draft release with the MSI, the .deb, the
   Store's MSIX and their SHA-256 sums.
6. Wait for the run to finish (`gh run watch`, or `gh run list --workflow release.yml`) and check
   the draft lists every file (`gh release view v<version>`). Only then tell the owner to publish
   the draft and upload the MSIX to Partner Center. If the run fails, fix it on main, delete the
   tag locally and on GitHub (with the owner's OK) and tag again.
7. Store texts: if anything users see changed, draft the changes for the owner to paste (the
   current listings are in the owner's notes, outside the repo; ask for them).

Testing the MSIX locally on Windows: `./gradlew :app:packageMsix`, then
`android/app/msix/sign-for-testing.ps1` signs a copy with a self-signed certificate (never
committed) for `Add-AppxPackage`. The MSIX's identity is Partner Center's (`orbt.msix*` in
`android/gradle.properties`); its version is `<major>.<minor>.<build>.0`.
