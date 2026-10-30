# The UI (Android and desktop)

Compose Multiplatform with Material 3 Expressive (Google, 2025), ported screen by screen from
`apple/ORBT/UI`. The layout is the iOS app's; the look is the platform's: Material 3 Expressive
here as HIG and Liquid Glass there. Each screen follows its Swift counterpart; the Swift file is
named in each stub's doc comment.

## Rules
- **Native components only**, as the Swift app uses SwiftUI's own with no custom overrides: stock
  Material 3 Expressive components and patterns as Google ships them (`MaterialExpressiveTheme`
  with the expressive motion scheme, `ui/theme/Theme.kt`; the Expressive API is opted into for
  the module in `build.gradle.kts`). Where Expressive replaces a component, use its version:
  - Tabs: `NavigationSuiteScaffold` with `NavigationSuiteItem` and
    `NavigationSuiteScaffoldDefaults.navigationSuiteType` (the short navigation bar; the wide
    navigation rail where a window would show one); panes: `ListDetailPaneScaffold`.
  - Top app bars: where iOS has a large title, a flexible app bar that collapses on scroll
    (`exitUntilCollapsedScrollBehavior`): `LargeFlexibleTopAppBar` on the tab roots
    (Repertoires, Today, Statistics, Settings), `MediumFlexibleTopAppBar` on pushed screens;
    `TopAppBar(title, subtitle)` where iOS's title is inline (the board screens).
  - Choosing one of a few options: a connected button group (`components/ChoiceButtonGroup`:
    `ToggleButton`s with `ButtonGroupDefaults.connected*ButtonShapes`), never `SegmentedButton`;
    tabs switch content.
  - Buttons morph when pressed: `shapes = ButtonDefaults.shapes()` on every button,
    `IconButtonDefaults.shapes()` / `toggleableShapes()` on icon buttons (`TooltipIconButton`).
  - Waiting: `LoadingIndicator` (and `PullToRefreshDefaults.LoadingIndicator` for pull to
    refresh); progress of a task (downloads, Study's countdown): `LinearWavyProgressIndicator`,
    `CircularWavyProgressIndicator`. A spinner of 12–16 dp inside a row stays
    `CircularProgressIndicator` (a loading indicator's shapes don't read that small); the app's
    data bars (coverage, studied, how much to learn) are values, not progress: plain
    `LinearProgressIndicator` without stop indicator.
  - Lists: `ListItem`; a pane's selectable rows use its `selected`/`onClick`/`onLongClick`
    overload, inset 12 dp so the selected row shows its rounded shape.
  - Board screens: `HorizontalFloatingToolbar` with its FAB (below).
  - Also `ModalBottomSheet`, `AlertDialog`, `Switch`, `Slider`, the collapsed `SearchBar` (in
    the outline sheet), plain tooltips on every icon-only action, Material Symbols (`Icons.*`,
    `components/Symbols.kt`), the platform's back handling, dynamic color.
  Don't hand-roll what Material has, don't restyle Material components to look like iOS, and let
  containers supply titles, spacing and typography. Custom drawing only where no component
  exists: the board, Anki-style progress bars, charts.
- **Meanings, not hues** (`Design/COLORS.md`, "Android and desktop"): a view colors something by
  what it means — `ThemeColor.learned.color`, `ThemeColor.learned.lighter().color`, and where a
  meaning fills a surface its tonal container and the content on it
  (`ThemeColor.learned.container.color`, `.onContainer.color`) — or uses a Material role
  (`MaterialTheme.colorScheme.*`), or the board's colors (`OrbtTheme.board`). Hues by name only
  in `ui/theme`; the commit hook blocks them elsewhere. Never color alone: with a symbol, text or
  shape.
- **Rules live in the core** (`orbt-core`); models are thin wrappers that forward to it.
- **Navigation goes through the shell.** A screen asks for a `Destination` with
  `navigate(destination)` and goes back with `onBack`; it never builds another screen or edits
  `AppShell.kt`/`ShellModel.kt`. A screen with `onBack == null` shows no back arrow (nothing to go
  back to in that pane).
- **The iOS layout is the base.** Each board screen puts its actions where the Swift app does
  (`BuilderView.swift`, `DrillView.swift`, `AnalysisView.swift`: the `!split` branch for a phone,
  the split view's for two panes), in Material's terms.
- **Board screens share one bar.** Build, Study and Analysis have a top app bar with the
  screen's title over the repertoire's name (`TopAppBar(title, subtitle)`; Analysis: over where
  its lines come from, "Cloud · depth 50", nothing while the engine is off), back and the ⋮ menu;
  on two panes it is the list pane's, over the panel, as on iPad. Their bottom bar is Material 3
  Expressive's floating toolbar (`components/BoardToolbar`, `HorizontalFloatingToolbar`), on
  phones as on tablets: icon-only items named by a tooltip, back and forward kept together,
  Discard a text button; the main action (Save, Next Line) the FAB beside it (`BoardToolbarFab`,
  Material's toolbar and FAB pairing).
  - One pane (a phone, as iPhone's glass bar): the toolbar floats at the bottom over the content,
    which scrolls under it (`FloatingToolbarScaffold`; lists take its bottom padding so their last
    row scrolls clear). Build: back and forward, then Biggest Gap, Study Branch, Analysis (while a
    line is being built: Analysis, Discard). Study: Hint, then Browse Repertoire, Analysis.
    Analysis: back and forward only, centred.
  - Two panes (as iPad): no top app bar over the board; under it, as wide as it, the toolbar with
    back and forward, the move list, then Analysis (and Discard). The panel's actions are in the
    list pane's top app bar, before ⋮: Biggest Gap and Study Branch in Build, Hint and Browse
    Repertoire in Study.
  - The engine: Analysis's top app bar has its toggle before ⋮ (Material's filled icon toggle,
    filled while on, named "Engine"), on phones and tablets. Build's and Study's Analysis button is
    in their bottom toolbar, so the engine's symbol up there reads as the engine.
- **One move list.** The moves of the line on the board are `components/MoveList` where iOS has
  them: under the board on a phone (Build and Study; Analysis has them in its Moves tab, as on
  iPhone), inside the floating toolbar on two panes (as iPad's bar under the board). A row of
  moves that scrolls sideways, the move on the board highlighted and kept in view, moves ahead
  faint, unsaved ones in italics, the start position a button leading it, its ends faded where it
  scrolls on (iOS's soft scroll edge); back and forward are toolbar buttons.
- **Board screens fill panes.** Build, Study, Study All and Analysis take a `pane: BoardPane`:
  `Whole` (one pane: a phone, a tablet in portrait), `List` (the list pane of Material's
  list-detail layout on wider windows, on the left: the top app bar over the panel, what you pick
  from: replies, explorer, counts) and `Detail` (the detail pane, the rest of the window: the board
  as large as it fits, the floating toolbar under it; `components/BoardDetailPane`). The shell
  calls the screen once per pane with the same model. The panes are Material's
  (`calculatePaneScaffoldDirective`): one up to medium width, two or more on expanded; their
  widths are Material's defaults.
- **Shared components** (`components/`) only for what Material lacks; a component one screen uses
  stays in that screen's package.

## Packages
| Package | What | Files (owner) |
|---|---|---|
| `ui` | the shell: destinations, back stack, panes, tabs, sheets, full-window screens | `Destination.kt`, `ShellModel.kt`, `AppShell.kt` (shell only); `Placeholder.kt` (temporary, delete once unused) |
| `ui.theme` | Material theme, app color, meanings, board colors | `Theme.kt`, `AppColor.kt`, `BoardTheme.kt`, `Hues.kt`, `DynamicColor.*.kt` |
| `ui.components` | coverage, studied and segmented bars, score bar, due counts, labels, status badge, empty state, connected button group (`ChoiceButtonGroup`), board column and detail pane, `OpenDocument`, `Format`, `Symbols`, `BoardPane`, `BoardToolbar`, `MoveList`, `TooltipIconButton` | shared |
| `ui.library` | `LibraryScreen` (list pane / Repertoires tab), `TodayPane` (detail with no selection), `SetupScreen` | library |
| `ui.overview` | `OverviewScreen`, `RepertoireSettingsScreen`, `StudyOptionsSheet` | overview |
| `ui.builder` | `BuilderScreen`, `BuilderModel` | Build |
| `ui.analysis` | `AnalysisScreen`, `AnalysisModel` | Analysis |
| `ui.training` | `DrillScreen`, `DrillModel`, `StudyFinishedScreen` (shown by Drill in place), `StudyAllScreen`, `StudyAllModel` | Study |
| `ui.statistics` | `StatisticsScreen`, `CardInfoSheet` | Statistics |
| `ui.settings` | `SettingsScreen`, `AcknowledgementsScreen` | Settings |
| `ui.board` | `Board`, `BoardArrow`, `BoardBadge` | board |
| `ui.tour` | `TourGuide` (steps, targets, `tourTarget`, `TourScreen`), `TourSpotlight` (scrim with cut-outs and a coach-mark card), `TourStudyCard`, `SkipTourButton`; the Tour section is `library/TourSection.kt` | tour |

A screen's agent owns its package; the model constructors and screen signatures are the shell's
contract (add optional parameters freely; change required ones together with the shell).

## Destinations (`Destination.kt`) and where the shell shows them
| Destination | Phone | Wide window (2–3 panes) |
|---|---|---|
| `Library` | Repertoires tab (Today first) | list pane; detail is `TodayPane`, extra (large windows) the statistics |
| `Overview(entryId)` | pushed | detail pane beside the list; on large windows the extra pane: its statistics (two panes: under the overview, `statisticsInline`) |
| `Builder(entryId, start, showGaps)` | pushed on its overview | the whole window: panel (list pane, left) + board (detail pane) |
| `Drill(entryId, kind)` — Study, LearnMore, Practice, Branch(node) | pushed | panel + board |
| `StudyAll(entryIds)` | pushed | panel + board |
| `Analysis(entryId, startFen, moves, orientation, origin)` | pushed on the screen it came from | panel + board; popping calls `AnalysisModel.finish()` |
| `Statistics(scope)` | All: the Statistics tab; one repertoire: its overview | beside Today / the overview |
| `RepertoireSettings(entryId)`, `Setup(mode)`, `Settings`, `Acknowledgements` | full window | full window |
| `CardInfo(entryId, node)`, `StudyOptions(entryId)` | bottom sheet | bottom sheet |

Build or Study opened from another board screen keeps only the overview and the screen it was
opened from under it (Swift's `openScreen`). Models are made before a screen is pushed and closed
(`close()`) after it leaves the stack. The shell is a ViewModel: it survives rotation.
