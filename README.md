# Opening Trainer

A free, open-source opening repertoire trainer for iPhone and iPad, in the spirit of
Chessbook, without a subscription.

- **Your repertoire is a PGN** in iCloud Drive (Files › Opening Trainer). Create one, or
  import an existing PGN, which is copied into that folder. Every edit is written to the file immediately, and changes from other devices
  are merged in.
- **Coverage** from the Lichess opening explorer (masters, or Lichess games filtered by
  speed and rating). Pick a target such as "cover every move seen once in 500 games" and
  the app shows each gap, how often you'd meet it, and a completion bar per move.
- **Spaced repetition** with Anki's scheduler (learning steps, FSRS, daily limits) per position, plus "study this branch". Works offline.
- **Analyze on Lichess** opens the current line in the Lichess analysis board.

## How coverage is computed
For each position, *reach* is the probability of getting there: your own moves count as
1, and each opponent move multiplies by its share of games in the explorer. An opponent
reply is *required* when its reach is at least 1/N (your target) and the position has
enough games. A gap is a required reply you have no line for, or a position where it's
your move and you have none. Completion is the frequency-weighted share of required
replies that are covered, recursively.

Results are cached per node. Editing a line only recomputes that line's subtree and its
ancestors; new statistics only recompute the positions they belong to. Statistics are
cached locally by position (FEN without move counters), so each position is fetched once.

## Building
Requires Xcode 26 and iOS 26.

```
xcodebuild -project openingTrainer.xcodeproj -scheme openingTrainer -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
cd OpeningCore && swift test
```

Lichess login uses OAuth with PKCE and needs no client registration.

## License
AGPL-3.0-or-later. The study scheduler is ported from
[Anki](https://github.com/ankitects/anki) (AGPL-3.0, Ankitects Pty Ltd and contributors) and
[fsrs-rs](https://github.com/open-spaced-repetition/fsrs-rs) (BSD-3-Clause, Open Spaced
Repetition). Piece set "cburnett" (GPLv2+) via Lichess. Chess rules by
[chesskit-swift](https://github.com/chesskit-app/chesskit-swift) (MIT).
