# Deviations

Where the Rust core differs from the established source it follows (Anki, fsrs-rs, lichess's
crates). Each entry says why.

- **PGN: our parser and writer, not pgn-reader.** Comment placement (comments right after
  "(" become pre-comments of the variation's first move, `%` escape lines, `!?` glyphs as
  NAGs) and the writer's exact output are the file format: re-saving must not reformat a
  user's repertoire. pgn-reader attaches comments differently. Chess rules still come from
  shakmaty, by the same author.
- **Filtered decks are shuffled with `StdRng` seeded by the day**, not SQL's `random()`, so
  a branch drill keeps its order for the day.
- **No load balancer.** Anki falls back to plain fuzz without it, as here.
- **Day numbers from a fixed epoch (1 Jan 2020 local time)**, not the collection's creation,
  so every device and repertoire agrees. The platform computes them, as Anki takes the UTC
  offset from its caller.
- **Today's stats also count distinct moves (`Today::card_count`)**, which Anki's today
  graph doesn't: the library's progress ring sets the moves answered today against those
  still due, and answers alone count a relearned move twice.
- **Statistics have a one-week range** besides Anki's month, three months, year and all time:
  the summary cards show this week, as Apple's Health and Fitness do.
- **Move counts over time (`stages_by_day`)** replay the review log into Anki's card-count
  groups for each past day; Anki only shows today's counts. The owner wants to see moves
  reach mature. Suspended moves count in the stage they were in.
- **Engine analysis asks Lichess for a cloud eval at every ply** (lichess mobile asks only
  before ply 15), and skips the local engine where the cloud eval is depth 30 or more with
  every line asked for: opening positions are what this app analyses, and the owner wants no
  engine time spent where Lichess already has a deep answer.
- **Sync merges unions, not three-way.** `sync` keeps the last remote version each device took
  in and merges only when both sides changed since, with the merges iCloud conflict versions
  already use (the PGN's tree union, `Sidecar::merged`, the review log by id). A line deleted
  on one device while the other also edited the file therefore comes back, as with an iCloud
  conflict; a deletion alone carries over. An edit wins over a deletion of the whole file on
  another device. Drive's changes are detected by `md5Checksum` (its v3 files have no
  `etag` field) and the upload is conditional on the download's `ETag` header with
  `If-Match`, which Google documents for v2 only: check the 412 on the live API before
  shipping.
