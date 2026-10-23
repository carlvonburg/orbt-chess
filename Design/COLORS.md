# Colors

How the app uses color. Everything lives in `apple/openingTrainer/UI/Components/Palette.swift`:
the `Theme` (one per app color, in the environment) decides every hue, and views only name a
meaning (`ThemeColor`: `.built`, `.learned`, `.learning`, `.new`, `.todo`, `.correct`,
`.wrong`, `.failure`, `.ahead`, `.inactive`), never a hue (the commit hook blocks `.orange`, `Color(red:` …
in `UI/` outside `Palette.swift`).

## Rules
1. **Two layers.**
   - The **accent** is the control color: tappable and selected things (buttons, selection,
     links, the prominent Study button, segmented pickers). It is the **app color** chosen in
     Settings › Appearance: **Multicolor** (the default): blue controls, board and Built bars,
     with Anki's colors for studying (below); then the Mac's accent colors: Blue, Indigo (the
     app icon's color), Purple, Pink, Red, Orange, Yellow, Green or Graphite, each shown as a
     strip of the board it gives. Every view takes the app color through the tint (`.tint`,
     never `Color.accentColor`, which on the Mac is the system accent). On the Mac the app
     color follows the system accent (`AppleAccentColor`; none is Multicolor): when it
     changes, the app color becomes it; a color picked in Settings stays until the next
     change.
   - **Meanings** (`ThemeColor`) are one set, resolved by the theme of the app color
     (table below). **Multicolor** gives each meaning its own system color, Anki's for
     studying. Every other app color is **tinted**, the way Apple tints accented widgets and
     watch complications (HIG Widgets › Accented, Complications › tinted mode): the app color,
     the label colors and red for wrong, lighter shades for levels (young, Anki's learning),
     so the bars and counts sit with the board. Text and position tell the meanings apart
     where they share a color.
2. **One meaning per color within a theme**, except where a theme shares on purpose (tinted:
   the app color for building, learned, correct and to do; Multicolor: blue for building and
   new, green for learned and correct, red for learning and wrong), always with text or a
   shape to tell them apart.
3. **Never color alone.** A meaning color always comes with a symbol, text or shape
   (✓/✕ badges, empty coverage bars, dashed arrows, labelled counts), for color blindness and for the
   accent overlap.
4. **Anything that asks you to act is colored.** Neutral is only for decoration and for
   information that needs nothing from you and has its own text. Remove a color only when
   nothing becomes less clear without it.
5. **Let Apple theme.** System colors and semantic styles (`.primary/.secondary/.tertiary`,
   `.fill.*`, `.background.*`, materials) adapt to dark mode, Increase Contrast and Liquid
   Glass. Custom values only where no system color fits (the board squares), as asset color
   sets with Any, Dark and High Contrast variants.
6. **Selected rows.** On a row with the accent selection fill (the Mac sidebar), every
   meaning color turns white (`backgroundProminence == .increased`), as Apple's own styles do:
   lighter shades at 75%, learning at 55%, so bars and counts stay readable in every theme.
7. **Restraint (HIG):** one prominent control per screen; color the background of the
   primary action, not its label; glass stays colorless otherwise.

## Theme meanings (`ThemeColor`)
One set of meanings, resolved by the theme of the app color. **Multicolor** gives each meaning
its own system color (Anki's for studying). Every other app color is **tinted** like Apple's
accented widgets: the app color, the label colors, and red for wrong.

| Meaning | Multicolor | Tinted | Where |
|---|---|---|---|
| `.built` | blue | the app color | the covered part of a `CoverageBar` (on a neutral track: what is left, gaps and lines not checked yet alike): Built bars, the overview, the Build header, replies, the gap list; your saved moves' row tint (8%), the transposition icon and chips, "Coverage target reached", the "Main" swipe, Welcome "build" |
| `.learned` | green | the app color | the review due count, mature moves (young: `.learned.lighter()`, mixed 45% toward white) in the studied bar, legends and Statistics, studied today, the "done for now" header, Welcome "study" |
| `.learning` | red | secondary label gray | the learning due count, relearning (learning: `.learning.lighter()`) in the studied bar, legends and Statistics |
| `.new` | blue | label color | the new due count, Statistics' new group, "New move" in the drill |
| `.todo` | orange | the app color | gap counts, "Your move is missing", "That's your alternative", the streak, leeches, Welcome "gaps" |
| `.correct` | green | the app color | "Correct", correct % |
| `.wrong` | red (purple when the app color is red or pink) | same | the ✕ badge and "Not quite", Again, overdue |
| `.failure` | Apple's red | same | error messages, the Delete swipe |
| `.ahead` | cyan | same | the Reviews chart |
| `.inactive` | gray | secondary gray at 40% | suspended in Move Counts and legends |

Graphite tints with indigo (its gray would read as learning). Multicolor uses blue for both
building and new; they never share a bar. The board has its own colors (below).

The accent is not a meaning: it is the app color itself, on buttons, selection, sliders,
switches and single-series charts.

Neutral: text, fills, cards, zero due counts (tertiary), the comment background, the track of a
`CoverageBar` and of the studied bar, "Excluded", "Not needed" (only the move name dimmed), the
transposition callout's card.

A new meaning: Multicolor takes a free system color (teal, mint, brown, indigo, pink); tinted
themes a label color or a shade of the app color.

## Statistics
| Chart | Colors |
|---|---|
| Move Counts | `.new`, `.learning.lighter()` (learning), `.learning` (relearning), `.learned.lighter()` (young), `.learned` (mature), `.inactive` |
| Reviews | learning and relearning `.learning` (lighter / full), young and mature `.learned` (lighter / full), `.ahead` |
| Answer Buttons, card info | Again `.wrong` |
| Future Due | the tint; overdue `.wrong` |
| Calendar, Intervals, Difficulty, Stability, Retrievability, Hourly | accent (bars only count; the calendar by intensity) |
| Weakest Moves | leech `.todo` |

## Board (`BoardTheme` in Palette.swift)
The board is content with its own theme: the same in the app's light and dark appearance
(dimmer squares in dark). Its squares are tinted toward the app color (`AppColor.board`), so
it carries the app's look. Its overlays are tinted the same way as
progress (Apple's tinted mode): one **ink**, the app color mixed 55% toward black, told apart
by width, opacity and dashes. The app color itself would vanish on its own board, the ink
stands out by lightness and keeps the hue.

| Element | Color | Shown in |
|---|---|---|
| squares | `BoardLight` `#E4E6E9` / `BoardDark` `#8E959E` (dark appearance `#C4C8CD`/`#737A84`; High Contrast wider), mixed 14% / 28% toward the app color | everywhere |
| last move / selected square | the app color 50% / 75% (graphite: the ink 25% / 40%) | everywhere |
| legal moves | black dots 22%, rings on captures 25% | moving a piece |
| your move | ink, main bold 85%, alternatives thin 50% | Build, your turn |
| reply you cover | ink, width and opacity by share | Build, their turn |
| gap | ink, dashed, by share (like the empty coverage bar: a shape, not a hue) | Build, their turn |
| hint | ink (100%, or 60% after a miss) | Study |
| correct / wrong | ink ✓ / red ✕ (`.wrong`) badge on the destination square | Study |
| engine lines | graphite `#2C2C2E`, best 70%, then 45%, 30% (quiet: often three) | Analysis |
| coordinates | the opposite square's color | everywhere |
| promotion | black 35% dim, pieces on a material | promoting |

## What changes when you pick an app color in Settings (`Theme.color(_:)`)
Every app color changes the tint (controls), tints the board's squares toward it and gives the
board its ink. Multicolor keeps the meaning colors above; every other app color tints them
(table above). The one stand-in left: `.wrong` is purple when the app color is red or pink.

Measured (OKLab ΔE of each overlay against the weaker of its two squares, ≥ ~10 clearly
visible), on all nine boards in light and dark appearance: the ink at 38% (the rarest reply
or gap) 10.2–14.4, at 85% 23–33; the last move 7.1–11.7 and the selected square 10.4–15.4
(graphite's ink 5.7–6.9 and 10.1–12.2); the engine's graphite 8–12 at 30%, 12–18 at 45%. A
white engine line was tried and fails on the light squares (3–6). Brown barely tints the slate
(chroma 0.6), so it isn't offered. A board swallows its own hue (the app color at 40% over its
board: 6–9; lichess brown: orange 6; chess.com green: green 6), which is why the overlays use
the ink, not the app color.

## App icon
The icon keeps its own indigo (`#6B64B8`, `#3F3A8C`, outline `#2B2760`; dark icon
`#2A2650`/`#14122B`). It has the same hue as Apple's indigo (~245°), the default app color until October 2026 (now blue).

## Adding a color
1. Name the meaning. If an existing role already means it, use that role.
2. Otherwise take a free system color, add a `ThemeColor.Role`, its hue (and stand-in) in
   `Theme.color(_:)`, a `ThemeColor` accessor, and rows above.
3. Pair it with a symbol or text, and check light, dark and Increase Contrast.

Sources: Apple HIG [Color](https://developer.apple.com/design/human-interface-guidelines/color),
[Materials](https://developer.apple.com/design/human-interface-guidelines/materials),
[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility).
