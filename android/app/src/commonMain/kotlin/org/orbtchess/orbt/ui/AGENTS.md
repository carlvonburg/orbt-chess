# The Compose UI (Android and desktop)

Each screen is ported from its Swift counterpart (named in the file's doc comment): the layout
is the iOS app's, the look Material 3 Expressive's.

- Stock Material 3 Expressive components as Google ships them; where Expressive replaces one,
  use its version:
  - choosing one of a few options: `components/ChoiceButtonGroup` (connected `ToggleButton`s),
    never `SegmentedButton`; tabs switch content.
  - menus: `components/ExpressiveMenu`, never `DropdownMenu`.
  - lists: `ListItem` in segmented groups (`components/Sections`), as Android 16's Settings.
  - every button gets `shapes = ButtonDefaults.shapes()` (icon buttons
    `IconButtonDefaults.shapes()`), so it morphs when pressed.
  - waiting: `LoadingIndicator`; a task's progress: the wavy indicators; a 12–16 dp spinner in a
    row stays `CircularProgressIndicator`; data bars (coverage, studied) are plain
    `LinearProgressIndicator`s without stop indicator.
  - top app bars: `LargeFlexibleTopAppBar` on tab roots, the one-line `TopAppBar` elsewhere.
- Never restyle Material to look like iOS. Custom drawing only where no component exists: the
  board, Anki-style bars, charts. Shared `components/` only for what Material lacks; a component
  one screen uses stays in that screen's package.
- Colors: a meaning (`ThemeColor.*.color`, `.container`, `.onContainer`), a Material role or
  `OrbtTheme.board`; hues by name only in `theme/` (`Design/COLORS.md`).
- Navigation goes through the shell: a screen calls `navigate(destination)` and `onBack`; it never
  builds another screen or edits `AppShell.kt` / `ShellModel.kt`. Model constructors and screen
  signatures are the shell's contract (add optional parameters freely).
- Board screens put their actions where the Swift app does (`BuilderView.swift`,
  `DrillView.swift`, `AnalysisView.swift`: the `!split` branch for a phone, the split view's for
  two panes), in Material's terms: the floating toolbar (`components/BoardToolbar`), one move list
  (`components/MoveList`), panes from Material's `calculatePaneScaffoldDirective`.
- `components/Refreshable`'s pull to refresh is Android only: a mouse wheel leaves it stuck.
