# Colors

How the app uses color. Everything lives in `apple/openingTrainer/UI/Components/Palette.swift`:
the `Theme` (one per app color, in the environment) decides every hue, and views only name a
role (`ThemeColor`: `.done`, `.attention`, `.new`, `.wrong`, `.ahead`, `.inactive`,
`.failure`), never a hue (the commit hook blocks `.orange`, `Color(red:` …
in `UI/` outside `Palette.swift`).

## Rules
1. **Two layers.**
   - The **accent** is the control color: tappable and selected things (buttons, selection,
     links, the prominent Study button, segmented pickers). It is the **app color** chosen in
     Settings › Appearance, the Mac's accent colors: Indigo (default, Apple's system indigo,
     the app icon's color), Blue, Purple, Pink, Red, Orange, Yellow, Green or Graphite, each
     shown as a strip of the board it gives. Indigo uses the asset catalog's accent, so on the
     Mac a user-chosen accent replaces it for controls. So the accent **never carries
     meaning**; a red button next to a red ✕ is fine, the ✕ is not a button. The one
     exception is progress (below).
   - **Progress** is tinted, the way Apple tints accented widgets and watch complications
     (HIG Widgets › Accented, Complications › tinted mode): one color, the app color, plus
     the label colors, with levels by opacity like SF Symbols' hierarchical rendering. It
     follows the app color so the bars and counts sit with the board.
   - **Meaning colors** are system colors, one meaning each. The theme gives each meaning its
     default hue, and when the app color has that hue (or tints the board too close to it) a
     stand-in from another family, everywhere in the app (table below). Within a theme every
     hue still means one thing.
2. **One meaning per hue.** A new meaning takes a free system color, never one in use.
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
6. **Restraint (HIG):** one prominent control per screen; color the background of the
   primary action, not its label; glass stays colorless otherwise.

## Theme meanings (`ThemeColor`)
Views name the meaning; the theme picks the color. Defaults (Indigo, the default app color):

| Name | Default color | Meaning | Where |
|---|---|---|---|
| `.done` | green | done: covered, your move, correct, learned | "Coverage target reached", transposition icon and badges, reply arrows you cover, your-move and hint arrows, your saved moves' row tint, "Main" swipe, ✓ badge and "Correct", studied today, correct %, Statistics' young and mature, Welcome "build" and "study" |
| `.progress` | the app color (indigo for Graphite) | progress, tinted | the covered part of a `CoverageBar` (on a neutral track: what is left, gaps and lines not checked yet alike), gap counts, the review due count, mature moves in the studied bar and its legends (young: `.progress.opacity(0.5)`) |
| `.learning` | secondary label gray | moves you're learning | the learning due count, the learning part of the studied bar and its legends |
| `.unstudied` | label color | new, not studied yet | the new due count; the not-studied rest of the studied bar is its fill (`.quaternary`) |
| `.attention` | orange | something to do | gaps (dashed arrows, gap list), "Your move is missing", "That's your alternative", streak at risk, leech, Welcome "gaps" |
| `.new` | blue | new, not studied yet (Anki) | Statistics' new group, "New move" in the drill |
| `.wrong` | red | wrong, study again now | ✕ badge and "Not quite", Again, Statistics' learning and relearning (learning: `.wrong.opacity(0.5)`), overdue moves |
| `.ahead` | cyan | reviewed ahead (Anki's filtered decks) | Reviews chart |
| `.inactive` | gray | suspended | Move Counts chart |
| `.failure` | red (Apple's) | something failed, delete | error messages, the Delete swipe |
| board highlight | yellow | last move (42%), selected square (68%) | the board |
| engine | graphite `#2C2C2E` | engine lines | the analysis board |

The accent is not a meaning: it is the app color itself, on buttons, selection, sliders,
switches and single-series charts.

Neutral: text, fills, cards, zero due counts (tertiary), the comment background, the track of a `CoverageBar`, "Excluded", "Not needed" (only the move name dimmed), the
transposition callout's card, a streak that is safe today (primary).

Free for a new meaning: teal, mint, brown, indigo, purple, pink (indigo, purple and blue also stand in on some boards, see below). Any of them may also be the app
color, which is fine: the accent is only ever on controls.

## Statistics
| Chart | Colors |
|---|---|
| Move Counts | new blue, learning red 50%, relearning red, young green 50%, mature green, suspended gray |
| Reviews | learning red 50%, relearning red, young green 50%, mature green, ahead cyan |
| Answer Buttons, card info | Again red, Good green |
| Future Due | accent; overdue red |
| Calendar, Intervals, Difficulty, Stability, Retrievability, Hourly | accent (bars only count; the calendar by intensity) |
| Weakest Moves | leech orange |

## Board (`BoardTheme` in Palette.swift)
The board is content with its own theme: the same in the app's light and dark appearance
(dimmer squares in dark). Its squares are tinted toward the app color (`AppColor.board`; not
a Mac user's accent, which may be green or orange like the arrows), so it carries the app's
look.

| Element | Color | Shown in |
|---|---|---|
| squares | `BoardLight` `#E4E6E9` / `BoardDark` `#8E959E` (dark appearance `#C4C8CD`/`#737A84`; High Contrast wider), mixed 14% / 28% toward the app color | everywhere |
| last move / selected square | yellow 42% / 68% | everywhere |
| legal moves | black dots 22%, rings on captures 25% | moving a piece |
| your move | green, main bold 85%, alternatives thin 50% | Build, your turn |
| reply you cover | green, width and opacity by share | Build, their turn |
| gap | orange, dashed, by share | Build, their turn |
| hint | green (100%, or 60% after a miss) | Study |
| correct / wrong | green ✓ / red ✕ badge on the destination square | Study |
| engine lines | graphite `#2C2C2E`, best 70%, then 45%, 30% (quiet: often three) | Analysis |
| coordinates | the opposite square's color | everywhere |
| promotion | black 35% dim, pieces on a material | promoting |

## What changes when you pick an app color in Settings (`Theme.color(_:)`)
Every app color changes the accent and tints the board's squares toward it. Where the app
color has a meaning's hue (or tints the board so close to it that the overlay fades), that
meaning takes a color from another family, everywhere in the app. A close shade would fail
the same way (mint, teal and cyan arrows measure 6–7 on a green board).

| App color | Meaning colors that change |
|---|---|
| Indigo (default) | none |
| Blue | `.new`: blue → indigo |
| Purple | none |
| Pink | `.wrong`: red → purple |
| Red | `.wrong`: red → purple |
| Orange | `.attention`: orange → purple (board ΔE 7 → 15) |
| Yellow | `.attention`: orange → purple (6 → 18); board highlight: yellow → indigo (9 → 15) |
| Green | `.done`: green → indigo (7 → 14) |
| Graphite | none |

`.failure` (Apple's red), `.ahead`, `.inactive` and the engine never change. On the red board
gap arrows stay orange (ΔE 9, dashed).

Measured (OKLab ΔE of each overlay against its square, ≥ ~10 clearly visible; arrows at 45%,
the faint end): with these stand-ins every overlay stays at 9 or more on all nine boards (the
third engine line, faint on purpose, at 10). Brown barely tints the slate (chroma 0.6), so it
isn't offered. A strongly colored board swallows its own hue (lichess brown: orange 6;
chess.com green: green 6), and a graphite accent would make highlights invisible if they
followed the accent, so highlights and arrows never do.

## App icon
The icon keeps its own indigo (`#6B64B8`, `#3F3A8C`, outline `#2B2760`; dark icon
`#2A2650`/`#14122B`). It has the same hue as Apple's indigo (~245°), the default app color.

## Adding a color
1. Name the meaning. If an existing role already means it, use that role.
2. Otherwise take a free system color, add a `ThemeColor.Role`, its hue (and stand-in) in
   `Theme.color(_:)`, a `ThemeColor` accessor, and rows above.
3. Pair it with a symbol or text, and check light, dark and Increase Contrast.

Sources: Apple HIG [Color](https://developer.apple.com/design/human-interface-guidelines/color),
[Materials](https://developer.apple.com/design/human-interface-guidelines/materials),
[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility).
