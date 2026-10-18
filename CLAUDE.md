# Opening Trainer

Open-source (AGPL-3.0), subscription-free alternative to Chessbook for iPhone and iPad.
SwiftUI on iOS 26 with Liquid Glass. Repertoires are PGN files in iCloud Drive; opponent
statistics come from the Lichess opening explorer.

## How the owner uses the app (product guidance — every feature serves this)
1. Read a book or watch a video on an opening.
2. Enter its moves, including the opponent responses and the branches it explains.
3. When unsure why a move fails for the opponent, open the position in Lichess analysis
   (one tap, keeps the move history).
4. Come back and add the crucial lines they personally want to cover.
5. Train with spaced repetition, or drill everything under one branch.

Priorities, in order:
1. See which opponent moves are not covered yet (gaps), with "seen every N games".
2. Navigate the repertoire easily and add new lines quickly.
3. Hand off a position to Lichess analysis in one tap.
4. Spaced-repetition training, including training a single branch. Works offline.
5. Separate progress for building (coverage) and for learning (cards).

Requirements:
- Lichess stats are cached by EPD (FEN without move counters; ep square only if an
  en-passant capture is legal).
- A repertoire is a PGN in the app's folder (iCloud Drive, or Documents without iCloud):
  created there, or imported (copied in) from Files.
  Every edit is saved to the PGN immediately. Settings and training state live in a
  sidecar `<Name>.otrep.json`, never in the PGN; the review log is `<Name>.otlog.jsonl`
  (append-only, one Anki revlog entry per line).
- Each repertoire chooses its coverage database (masters, or Lichess speeds + rating
  buckets) and its coverage target ("cover moves seen once in N games").
- Chessbook screenshots only show how that app works; its layout is not a template.

Non-goals for now: auto gap filling, online game review, daily tasks, plans in a
position, model games, bundled engine.

## Layout
- `OpeningCore/` — local Swift package, no UI. Chess wrapper over
  chesskit-swift, PGN parser/writer, RepertoireTree, explorer stats model, coverage
  engine, training (Anki's scheduler ported in `Training/Anki/`). Test with `swift test` inside that folder.
- `openingTrainer/` — the app target (folder-synced group, new files are
  picked up automatically). `Lichess/`, `Storage/`, `UI/`.

## Transpositions (see RepertoireTree.merge)
Each position's lines are stored once. When a PGN move order reaches a position whose
lines already exist at another node (same chapter, not an ancestor), that node becomes a
leaf and its PGN moves are merged into the existing one (`transpositionTarget`). Chessbook
exports repeat the subtree under every move order (a 1.2 MB Semi-Slav: 189k moves, 5.5k
positions); such a file is rewritten compactly after opening. Coverage counts a leaf with a
target as `.transposition`, training lines and branch drills continue through it, and the
builder shows the target's moves and adds new moves there.

## Coverage model (see OpeningCore/Coverage)
Reach probability p: root 1; own moves keep p; opponent move multiplies by its share at
the parent (move games / position games). Opponent reply required when p·f ≥ 1/N and the
position has ≥ minGames games. Gaps: own-turn node with p ≥ 1/N and no saved move (and no
transposition), or a missing required reply. Completion C is the frequency-weighted mean
over required replies. Opponent moves the user excludes (sidecar `excludedMoves`, keyed by
the EPD before the move, so they apply at every transposition) are never required; a move
saved anyway is covered as usual. Values are cached per node and updated incrementally: an edit
recomputes only the edited subtree and its ancestors.

## Training (see OpeningCore/Training/Anki, ported from Anki's rslib scheduler)
Follow Anki's code, not invented rules. A card is a position where it's your move (one per
EPD). States, learning steps (1m 10m, relearn 10m), FSRS-6, fuzz, day rollover at 4 AM,
learn-ahead 20 min, queue order and daily limits (preset / this repertoire / today only)
are Anki's. Chess additions, kept minimal and listed in `Study.swift`: lines start at move 1
and the practice mode decides who plays your earlier moves; one line answers every queued
card on it; moves you play that aren't due are reviews ahead (filtered deck); new cards are
introduced a line at a time (most reached first) and a started line is finished past the
daily limit; reviews due the same day are ordered by reach. Grading is Again/Good only
(wrong, hint or browsing = Again). Ported files keep Anki's AGPL header.
The UI follows Anki's deck list → deck overview → deck options, and says "moves", never
"cards". Progress uses Anki's card-count groups (learning, young, mature), not a percentage.
Study All runs repertoires one after another (Anki would mix a parent deck's reviews).

## Conventions
- Code in OpeningCore is pure Swift, `Sendable` value types, no UIKit/SwiftUI.
- App code is MainActor by default (`SWIFT_DEFAULT_ACTOR_ISOLATION`).
- Explorer: one request at a time, paced (~0.6 s), Retry-After on HTTP 429, re-login on 401.
- Fetch policy: the position on screen first; plus a background coverage check only while a
  repertoire is open in the builder, limited to opponent-to-move positions above the target
  (bounded by the target, not PGN size: a 4.4k-position PGN needs ~15 requests at 1-in-500).
  Never fetch every position of a PGN.
- Build: `xcodebuild -project openingTrainer.xcodeproj -scheme openingTrainer -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' build`
