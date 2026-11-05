# Colors

The color system of both apps. Views name a meaning, never a hue: on Apple `ThemeColor` in
`apple/ORBT/UI/Components/Palette.swift`, on Android and the desktop `ThemeColor` in
`android/app/.../ui/theme` (hues by name only there; the commit hook blocks them elsewhere). The
values and the measurements behind them are commented in those files.

## Rules
1. **Two layers.** The **accent** is the control color (buttons, selection, links, the
   prominent action): the **app color** chosen in Settings › Appearance — Multicolor (the
   default: blue controls, Anki's colors for studying) or one of the Mac's accent colors. On the
   Mac it follows the system accent. Views take it through the tint (`.tint`, never
   `Color.accentColor`; on Android Material's primary). **Meanings** are one set, resolved by the
   theme of the app color (table below).
2. **One meaning per color within a theme**, except where a theme shares on purpose, always
   with text or a shape to tell them apart.
3. **Never color alone.** A meaning color comes with a symbol, text or shape (✓/✕ badges,
   empty coverage bars, dashed arrows, labelled counts).
4. **Anything that asks you to act is colored.** Neutral is for decoration and for information
   that needs nothing from you. Remove a color only when nothing becomes less clear.
5. **Let the platform theme.** System colors and semantic styles on Apple, Material's roles on
   Android; custom values only where nothing fits (the board), as asset color sets with Dark and
   High Contrast variants on Apple.
6. **Selected rows.** On a selected row meaning colors take the row's content color (white on
   the Mac's accent fill, the secondary container's content on Android): lighter shades at 75%,
   learning at 55%.
7. **Restraint (HIG):** one prominent control per screen; color the background of the primary
   action, not its label.

## Meanings
Multicolor gives each meaning its own system color (Anki's for studying). Every other app color
is **tinted**, like Apple's accented widgets: the app color, the label colors and red for wrong.
On Android, a named hue is a Material custom color harmonized with the primary at chroma ≤ 36,
and every meaning also has a container and on-container role.

| Meaning | Multicolor | Tinted | Android tinted | Means |
|---|---|---|---|---|
| built | blue | app color | `primary` | covered lines, saved moves, transpositions |
| learned | green | app color | `primary` | reviews due, mature (young: lighter) |
| learning | red | secondary label | `onSurfaceVariant` | Anki's learning (lighter) and relearning |
| new | blue | label | `onSurface` | not studied yet |
| todo | orange | app color | `primary` | gaps, a missing move, the streak, leeches |
| correct | green | app color | `primary` | ✓, "Correct", correct % |
| wrong | red (purple when the app color is red or pink) | same | same | ✕, Again, overdue |
| failure | Apple's red | same | `error` | errors, Delete |
| ahead | cyan | same | same | reviewed ahead |
| inactive | gray | secondary at 40% | `onSurfaceVariant` at 40% | suspended |

Graphite tints with indigo (its gray would read as learning). Lighter shades (young, Anki's
learning) are 45% toward white; on Android in dark appearance, 45% down toward tone 30.

## Board
The board has its own theme, the same in light and dark appearance (dimmer squares in dark):
squares tinted toward the app color, and every overlay in one **ink** (the app color 55% toward
black on Apple, tone 28 on Android), told apart by width, opacity and dashes: your moves bold,
alternatives thin, covered replies by share, gaps dashed, the hint. Last move and selected square
are the app color at 50% / 75% (graphite: the ink). The ✓ is `correct` (the ink in tinted
themes), the ✕ `wrong`, the engine's lines graphite.

## Adding a color
1. Name the meaning. If an existing role already means it, use that role.
2. Otherwise take a free system color (teal, mint, brown, indigo, pink) for Multicolor and a
   label color or a shade of the app color for tinted themes; add the role on both platforms
   and a row above.
3. Pair it with a symbol or text, and check light, dark and Increase Contrast.
