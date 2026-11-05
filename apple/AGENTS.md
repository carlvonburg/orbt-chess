# The Apple app (iPhone, iPad, Mac)

- One multiplatform target, not Catalyst. `ORBT/` and `ORBTTests/` are folder-synced: new files
  are picked up without editing the project.
- Swift does IO and platform work only; models are thin `@Observable` wrappers that forward to
  the core and re-read it when its revision changes. `OpeningCoreRust/Sources/.../Additions.swift`
  holds conveniences, never rules.
- App code is MainActor by default. File IO and heavy core calls (open, save, remote merges) run
  off the main actor, one at a time through the document's `Writer`, each coordinated access
  passing that file's presenter.
- iCloud conflict versions are merged into the document (`mergeSidecarData`,
  `mergeRevlogData` for the sidecar and the log), then removed.
- Colors come from roles in `UI/Components/Palette.swift`; take the app color through `.tint`,
  never `Color.accentColor` (on the Mac that is the system accent).
- macOS bug (still present on macOS 27.2): a view pushed onto a NavigationStack inside a
  NavigationSplitView's sidebar column gets no usable height and renders blank. So the Mac keeps
  the three-column split, and only the iPad pushes in the sidebar (`#if os(iOS)` in
  LibraryView). Don't push in the Mac's sidebar.
- Mac builds need a development profile for the iCloud entitlement; add
  `CODE_SIGNING_ALLOWED=NO` to compile only. iPad simulator: `name=iPad Pro 13-inch (M5)`.
- A Release build (Archive) runs `scripts/check-release.sh`: it needs `Config/Secrets.xcconfig`
  (never committed) and an xcframework built from the current sources.
- The app icon (`ORBT/AppIcon.icon`) is the source for every platform's icon: use the
  `app-icon` skill to change it.
