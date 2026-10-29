# The UI (Android and desktop)

Compose Multiplatform with Material 3, ported screen by screen from `apple/ORBT/UI`. Each screen
follows its Swift counterpart; the Swift file is named in each stub's doc comment.

## Rules
- **Native components only**, as the Swift app uses SwiftUI's own with no custom overrides: stock
  Material 3 components and patterns as Google ships them — `NavigationSuiteScaffold`,
  `ListDetailPaneScaffold`, `Scaffold` + `TopAppBar`, `ListItem`, `ModalBottomSheet`,
  `AlertDialog`, `Switch`, `Slider`, `SegmentedButton`, `FloatingActionButton`, Material
  Symbols (`Icons.*`, `components/Symbols.kt`), the platform's back handling, dynamic color.
  Don't hand-roll what Material has, don't restyle Material components to look like iOS, and let
  containers supply titles, spacing and typography. Custom drawing only where no component
  exists: the board, Anki-style progress bars, charts.
- **Meanings, not hues** (`Design/COLORS.md`, "Android and desktop"): a view colors something by
  what it means — `ThemeColor.learned.color`, `ThemeColor.learned.lighter().color` — or uses a
  Material role (`MaterialTheme.colorScheme.*`), or the board's colors (`OrbtTheme.board`). Hues
  by name only in `ui/theme`; the commit hook blocks them elsewhere. Never color alone: with a
  symbol, text or shape.
- **Rules live in the core** (`orbt-core`); models are thin wrappers that forward to it.
- **Navigation goes through the shell.** A screen asks for a `Destination` with
  `navigate(destination)` and goes back with `onBack`; it never builds another screen or edits
  `AppShell.kt`/`ShellModel.kt`. A screen with `onBack == null` shows no back arrow (nothing to go
  back to in that pane).
- **Board screens fill panes.** Build, Study, Study All and Analysis take a `pane: BoardPane`:
  `Whole` (a phone, or one pane), `Panel` (the detail pane: what is beside the board) and `Board`
  (the extra pane: the board and what belongs with it). The shell calls the screen once per pane
  with the same model.
- **Shared components** (`components/`) only for what Material lacks; a component one screen uses
  stays in that screen's package.

## Packages
| Package | What | Files (owner) |
|---|---|---|
| `ui` | the shell: destinations, back stack, panes, tabs, sheets, full-window screens | `Destination.kt`, `ShellModel.kt`, `AppShell.kt` (shell only); `Placeholder.kt` (temporary, delete once unused) |
| `ui.theme` | Material theme, app color, meanings, board colors | `Theme.kt`, `AppColor.kt`, `BoardTheme.kt`, `Hues.kt`, `DynamicColor.*.kt` |
| `ui.components` | coverage, studied and segmented bars, score bar, due counts, labels, status badge, empty state, board column, `OpenDocument`, `Format`, `Symbols`, `BoardPane` | shared |
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
| `Library` | Repertoires tab (Today first) | list pane; detail is `TodayPane`, extra the statistics |
| `Overview(entryId)` | pushed | detail pane beside the list; extra pane: its statistics (two panes: under the overview, `statisticsInline`) |
| `Builder(entryId, start, showGaps)` | pushed on its overview | panel in detail, board in extra |
| `Drill(entryId, kind)` — Study, LearnMore, Practice, Branch(node) | pushed | panel + board |
| `StudyAll(entryIds)` | pushed | panel + board |
| `Analysis(entryId, startFen, moves, orientation, origin)` | pushed on the screen it came from | panel + board; popping calls `AnalysisModel.finish()` |
| `Statistics(scope)` | All: the Statistics tab; one repertoire: its overview | beside Today / the overview |
| `RepertoireSettings(entryId)`, `Setup(mode)`, `Settings`, `Acknowledgements` | full window | full window |
| `CardInfo(entryId, node)`, `StudyOptions(entryId)` | bottom sheet | bottom sheet |

Build or Study opened from another board screen keeps only the overview and the screen it was
opened from under it (Swift's `openScreen`). Models are made before a screen is pushed and closed
(`close()`) after it leaves the stack. The shell is a ViewModel: it survives rotation.
