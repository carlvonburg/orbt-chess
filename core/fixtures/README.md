# Golden fixtures

Outputs recorded from the Swift core (`OpeningCore`, since deleted) that the Rust core
reproduces. Do not edit by hand.

Files over 1 MB are gzipped (`name.json` → `name.json.gz`). Paths in this README name the
uncompressed file: read `<path>.gz` when `<path>` is absent (`golden::bytes` does). This
includes byte-exact files such as `inputs/semislav.pgn.gz` and `pgn/semislav.written.pgn.gz`.

## Re-recording

After an intended change, tests that support it write the Rust output into their fixture:

```bash
OT_REBASE_GOLDENS=1 cargo test -p ot-core --test golden_scheduler --test golden_study
```

Check the diff before committing. `scheduler/answers.json`, `queue/queues.json` (the
`berlin_filtered` days) and `session/*.json` were re-recorded this way when fuzz and the
filtered shuffle moved to Anki's `StdRng`; everything else is still the Swift output.

## Where the core differs from the recording

- chesskit-swift kept castling rights after a rook was captured on its home square (e.g.
  `KQkq` after `Rxa8`); shakmaty drops them, as FEN requires. This changes 22 of ~9,500
  positions, all in the Semi-Slav. The tests map the fixtures' keys with
  `golden::legacy_epds`.
- chesskit-swift kept the ep square after an en-passant capture and counted the halfmove
  clock up (`b - f6 1 17`); shakmaty clears it and resets the clock (`b - - 0 17`). Only the
  FEN differs; the EPD is the same.
- FSRS comes from the fsrs crate (f32, as in Anki), the Swift copy used f64: memory states
  differ around the 6th significant digit and are compared with a tolerance.
- Sidecars were written with Foundation's formatting (`"key" : value`) and a summary
  `computedAt`; they are compared as values, without it.
- Where Swift iterated a `Set` or `Dictionary`, the core breaks ties by EPD or node id (see
  "Unordered fields").

## Conventions

- JSON was written by Swift's `JSONEncoder` with sorted keys and unescaped slashes; pretty
  printed except files marked *compact*. Compare parsed values, not bytes (except `.pgn` and
  `.otlog.jsonl`, which are byte-exact file formats).
- Ids (`NodeID`, card ids, timestamps) are integers. Doubles are printed in Swift's shortest
  round-trip form; a whole double prints without a fraction (`1`, not `1.0`), so parse every
  number as f64 where the schema says double. Compare doubles exactly unless a field is noted.
- `null` means Swift `nil`. Dictionaries keyed by `NodeID` use the id as a string key.
- Positions are EPD strings (FEN without counters, ep square only when capturable).
- Cards (`Card`) and revlog entries (`RevlogEntry`) appear in their own Codable form, exactly
  as in the sidecar / log files: optional fields that are nil are **omitted**, enums are ints
  (`ctype` 0 new 1 learn 2 review 3 relearn; `queue` -1 suspended 0 new 1 learn 2 review 3
  dayLearn; revlog `type` 0 learning 1 review 2 relearning 3 filtered 4 manual 5 rescheduled).
- Common objects:
  - *timing*: `{daysElapsed, nextDayAt, now}` (`SchedTiming(daysElapsed:nextDayAt:now:)`).
    Scheduler/session fixtures use day `d` rolling over at `t0 + (d+1)·86400`, `t0 = 1700000000`.
  - *stats*: `{white, draws, black, moves: [{uci, san, white, draws, black, averageRating}]}` or null.
  - *tree*: see `tree/<name>.tree.json`.
  - *coverage node*: `{reach, status: {kind, target?}, completion, gapCount, gapMass,
    pendingCount, biggestGap, localGaps, replies, counts, seenEvery}`; a *gap* is
    `{node, kind: {kind: missingMove} | {kind: missingReply, uci, san}, mass, seenEvery}`
    (`seenEvery` of mass 0 is `Int.max` = 9223372036854775807); a *reply* is `{uci, san, share,
    reach, required, excluded, child, transposesTo, completion, games}`. `status.kind` is one of
    required, belowTarget, pending, unknown, gap, transposition (with `target`), alternative.
  - *engine*: `{nodes: {id: coverage node}, root, gaps, pendingPositions: [{epd, reach}]}`.

## Unordered fields

Where Swift's order comes from dictionary/set iteration, the fixture fixes an order and the
Rust side must compare as described:

- `pendingPositions`: Swift sorts by reach only; ties keep dictionary order. Fixtures sort by
  reach descending, then EPD ascending — compare as a set of `(epd, reach)` per equal reach, or
  sort the Rust output the same way.
- Intraday learning entries that compare equal (same `due`, and both or neither previously
  attempted, `reps == 0`) are built from dictionary iteration in the daily
  `CardQueues(cards:newCards:...)`. Queue snapshots therefore list `intradayLearningGroups` and
  `orderedGroups` as arrays of groups (inside a group the EPDs are sorted), next to the exact
  Swift order in `intradayLearning` and `ordered`. For a daily queue compare the groups; the
  exact lists are meaningful for filtered queues (built from the given EPD order, every learning
  card due `now`, so all tie but deterministically) and for entries inserted by `answered`.
  `hasTieAtFront` says whether the next card shown depends on a tie. Daily session simulations
  stop (`stoppedOnTie: true`) instead of picking one; none of the current fixtures do.
  `queue/queues.json` `anki_basic` contains a deliberate tie (`b3`/`g3`).
- `newCardOrder`: siblings with equal reach keep the tree's child order. Swift's `sort` is
  stable, so this *is* deterministic; Rust must use a stable sort (`sort_by`) to match.
  Reviews due the same day with equal priority are ordered by card id (deterministic).
- Set-valued fields (`chapters` of a node, `trainable`, `cardEPDs`, `suspendedCardEPDs`,
  `answered`, `played`, `missing`, `updateEPDs`, excluded moves) are sorted.
- `coverage/incremental.*`: the property test picks `missing.first` (random per run); the
  recorder uses `missing.min()` instead, and the ops list records the choice.

## Files

### `inputs/<name>.pgn`
Every PGN input, byte-exact. Inline PGNs from the Swift tests:
`sicilian_chapters` (PGNTests.sample), `writer_black_after_variation`,
`writer_black_after_comment`, `illegal_move`, `nonstandard_start`, `chapters_ab`,
`note_commands`, `merge_base`, `transposition` (TranspositionTests.pgn),
`transposition_chapters`, `transposition_three_orders`, plus `parser_edge_cases` (escaped tag
quotes, `%` lines, `;` comments, glyphs and `$n` NAGs, comments before variations, nested
variations, `0-0`, games without result token, FEN starts incl. black to move, promotion,
en passant). Files: `berlin` (Berlin-2026-09-22T19_03_40.239Z.pgn, 66 KB) and `semislav`
(Semi-Slav-2026-09-22T18_59_03.655Z.pgn, 1.2 MB).

### `pgn/<name>.parse.json`
`PGNParser.parse(text)`: `{games: [{tags: [{name, value}], comments, moves: [move], result}]}`,
`move = {san, nags, preComments, comments, children: [move]}` (`children[0]` continues the line,
the others are its variations). Compact for inputs ≥ 5000 characters (nesting makes pretty output huge). If the JSON exceeded 20 MB it
would be replaced by `{summary: true, gameCount, gameHashes}` (FNV-1a 64 of each game's compact
JSON); see `tree/manifest.json` for sizes — no file needed it.

### `pgn/<name>.written.pgn`
`PGNWriter.write(PGNParser.parse(text))`, byte-exact (games joined by a blank line, trailing newline).

### `tree/<name>.tree.json` and `tree/<name>.pgn`
`RepertoireTree(pgn: text)`. `.pgn` is `pgnText()`, byte-exact. JSON:
`{count, nodes: [node], chapters: [{tags, comments, result, name, passthrough: game|null}],
epdIndex: {epd: [id]} (insertion order), loadWarnings, mergedTranspositions, rereadCount,
rereadPGNTextEqual}`; `node = {id, parent, san, uci, fen, epd, ply, children (order matters),
chapters (sorted), comments, preComments, nags, note, sideToMove, transpositionTarget}` sorted
by id. `rereadCount`/`rereadPGNTextEqual` are for `RepertoireTree(pgn: pgnText())`. Compact for
trees ≥ 2000 nodes.

### `tree/manifest.json`
Sizes in bytes and node counts per input.

### `tree/edits.json`
Scripted edits. `edits`, `chapters`, `notes`: arrays of `{op, result, tree, pgnText}` (the tree
after each op; `result` is the returned node id or null). Ops: `new`, `parse`, `addMove {uci, after}`,
`addMoveSAN {san, after}`, `addLine {ucis, after}`, `promote {id}`, `delete {id}`,
`setNote {text, id}`, `setChapterTag {index, name, value}`, `mergeMoves {pgn, at}` (merges
`parse(pgn)[0].moves` at `at`; result = new node count). `mergeTree`: `{local, remote, added,
result, pgnText}` for `local.merge(tree: remote)` (TreeMergeTests).

### `coverage/<name>.<scheme>.<color>.json`
`CoverageEngine.recomputeAll` for each input tree, color `white`/`black`. Schemes:
- `synthetic`: CoveragePropertyTests' FNV stats (`makeSynthetic`), target 40, minGames 50.
- `synthetic_missing`: same, but no stats where `fnv1a64(epd) % 5 == 0` (gives pending nodes).
- `treestats`: LargeRepertoireTests' stats from the tree's own moves (child i gets 1000/(i+1)
  games, total +200; transposed positions use their lowest node id), target 500, minGames 25.
- `treestats_missing`: same, but no stats where `fnv1a64(epd) % 5 == 0`. Synthetic stats rarely
  contain the real trees' moves, so their reach drops below target and missing stats there give
  `unknown`, not `pending`; this scheme gives pending nodes inside the required region.

`fnv1a64` is CoveragePropertyTests.fnv: FNV-1a 64 over the UTF-8 bytes.

`{settings: {color, targetGames, minGames, excluded}, scheme, stats: {epd: stats|null}, nodes,
root, gaps, pendingPositions}`. `stats` holds every lookup the engine made, so the Rust test
needs no generator. Compact for trees ≥ 2000 nodes. Over 20 MB a file would become
`{summary: true, settings, scheme, root, gaps, nodeHashes: {id: fnv64 hex of compact JSON}}`;
see `coverage/manifest.json` (none does).

### `coverage/hand.json`
CoverageTests/TranspositionTests hand fixtures: `{name: {tree, pgnText, coverage}}` with
`coverage` as above (`scheme: "fixture"`), names `fixture`, `fixture_excluded`,
`fixture_excluded_saved_anyway`, `transposition_covered`, `below_target`,
`opponent_to_move_leaf`; plus `replies_at_unsaved: {epd, reach, settings, stats, replies}` for
`engine.replies(at:stats:reach:)`.

### `coverage/incremental.<color>.<seed>.json`
CoveragePropertyTests' random edit sequence (seeds 1–3, target 40, minGames 50) recorded as
operations: `{settings, seed, ops, finalTree, final, finalFull, finalStats}`. Each op is one of
`addMove {after, uci, added, missingInserted, updateEPDs}`, `delete {id, changedAt, updateEPDs}`,
`promote {id, changedAt, updateEPDs}`, `statsArrived {epd, changed}`, with `step`, `root` (root
coverage after the incremental update) and `missing` (positions without stats after the op).
Replay: apply the tree op, then `update(changedAt:epds:)` / `statsArrived(for:)` with stats =
synthetic unless in `missing` (an `addMove` with `missingInserted` adds the new node's EPD to
`missing` before the update). `final` is the incremental engine, `finalFull` a full recompute,
`finalStats` the lookups of the latter.

### `scheduler/answers.json`
`{t0, scenarios: [{name, config, epd, cardID, start: card|null, steps}]}`; each step
`{timing, rating (1 again, 3 good), filtered, takenMillis, position, before: card|null,
nextStates: {current, again, hard, good, easy}, card, revlog, fromQueue, leeched}` where
`nextStates` = `Scheduler.nextStates(before, id:, position:, timing:, filtered:)` and `card`,
`revlog` = `Scheduler.answer(...)`. A *state* is `{kind: new|learning|review|relearning,
position? , learning?: {remainingSteps, scheduledSecs, elapsedSecs, memory}, review?:
{scheduledDays, elapsedDays, easeFactor, lapses, leeched, memory}, intervalKind: {secs}|{days},
revlogKind, leeched}`; `memory` = `{stability, difficulty}` or null. `config` lists every
`DeckConfig` field. The next step's timing: learn queue → at `due` (+ delay); otherwise day
`due + daysLate` at 08:00 (+61 s per step). Scenarios: new cards (Good chain, Again/Good,
mixed with lateness) for 10 EPDs (different card ids → different fuzz), review on time / late
/ early filtered / branch session / without memory, relearn, leech tag/suspend/threshold,
steps across the rollover, day-learn, step and FSRS short-term configs, retention 0.8 with max
interval 30, retention 0.97. Fuzz is always on (seeded by card id + reps). Re-recorded from
the Rust core (see "Re-recording").

### `scheduler/vectors.json`
Unit vectors: `fuzzFactor` (`{seed (decimal string, u64), factor}`), `learningIntervalWithFuzz`
`{seed, secs, result}`, `review` (`{interval, minimum, maximum, bounds, noFuzz, fuzz: [{factor,
result}]}` for `constrainedFuzzBounds`/`withReviewFuzz`, and `{interval, previous, maximum,
minimumReviewFuzzInterval}`), `fuzzSeed {cardID, reps, seed}`, `fsrsNextStates {memory,
desiredRetention, daysElapsed, again|hard|good|easy: {memory, interval}}`, `retrievability`,
`learningSteps {steps, remaining, again, hard, good, current, remainingForGood,
remainingForFailed}`, `intervalKind {kind, secsUntilRollover, converted, revlog}`,
`leechThreshold {lapses, threshold, met}`. `fuzzFactor` and `learningIntervalWithFuzz` hold the
Swift generator's draws: only their ranges are checked.

### `queue/queues.json` (compact)
- `anki_basic`: AnkiSchedulerTests.queueOrderAndCounts plus a deliberate tie;
  `{timing, cards, newCards, limits, learnAheadSecs, steps: [{op, queue}]}`. Its snapshots
  omit the exact `intradayLearning`/`ordered` lists (their order is dictionary order).
- `berlin_mixed`: cases `default`, `review5_new3`, `review2_cap`, `review2_nocap`, `unlimited`,
  `zero` with learn-ahead 1200 (and `default` also with 0), the first three cards shown answered
  (Again, Good, Again) at now+10/20/30 s;
  `{timing, cards, newCards, priority: {epd: reach}, cases: {"<limits>.learnAhead<secs>":
  {limits, learnAheadSecs, steps}}}`; ops `build`, `remove {epd}`, `answered {epd, card, timing}`
  (the card from `Scheduler().answer`), `updateLearningCutoff {now}`.
- `berlin_filtered`: `CardQueues(filtered:cards:timing:)` for three days (shuffle seeded by the day).
- `intersperse`, `remainingLimits` vectors.

A *queue* snapshot is `{counts, currentDay, learnAheadSecs, currentLearningCutoff, main: [{epd,
kind: new|review|interdayLearning}], intradayLearningGroups: [[{epd, due, reps}]], orderedGroups:
[[epd]], intradayLearning: [{epd, due, reps}], ordered: [[epd, kind]], orderedKinds: {epd:
new|learning|review}, nextLearningDue, hasTieAtFront}`.

### `trainer/<name>.json`
`Trainer(tree:color:)` for `white_tree`, `takeback_tree`, `transposition`,
`transposition_three_orders` (black), `berlin`, `semislav` (black): `{color, tree, reach (from
treestats coverage), trainable, cardNodes (order matters), cardEPDs, suspendedCardEPDs,
expectedMoves {node: uci}, allLines [[id]], branchLines {node: [[id]]}, branchCardNodes,
newCardOrder (no reach), newCardOrderByReach, newCardOrderByReachPerBranch, lineThrough {node:
[id]} (first 200 card nodes, preferring reach), mixedCards, progress, progressEmpty}`.
Branches are the root's children and their first two children. `mixedCards` is the
deterministic card set used by queue and session fixtures (by new-card index and
`fnv1a64(epd) % 10`). Compact for trees ≥ 2000 nodes.

### `session/<name>.json`
Study sessions for the same trees: keys `"<empty|mixed>.<practiceMode>.<daily|branch>"` plus
`color, reach, t0, branch` (root's first child's first child). Daily sessions use limits
review 30 / new 5; branch sessions are filtered. Each: `{limits, startTiming, initialQueue,
lines, stoppedOnTie, finalCards, revlog, answered, played}`; each line `{now, countsBefore,
line: {nodes, target, roles: {index: auto|practice|answer.queued|answer.introduce|answer.reviewAhead}},
resumeIndex (vs. the previous line, shown = its last index), answers: [{index, epd, rating,
filtered, position, card, fromQueue}], countsAfter}` or `{waitUntil}` (no line: time jumps to
the next learning due). Simulation (like DrillView): `updateLearningCutoff(now)`, `nextLine`; for
each own move in index order time += 7 s; a role `answer.*` is answered (Again when
`fnv1a64(epd + answerCount) % 4 == 0`, else Good; `filtered = isFiltered || reviewAhead`,
takenMillis 7000) then `didAnswer`; every non-auto move is `didPlay`ed. At most 40 lines.

### `misc/card_ids.json`
`Card.id(for:)` for every Berlin EPD plus edge strings: `{cardIDs: [{epd, id}]}`.

### `misc/*.otrep.json`, `misc/sidecar_info.json`
`Sidecar.encoded()` byte-exact: `minimal`, `full` (cards, stats, limits, practice mode,
summary, last line, excluded moves, Lichess database), `masters`, `other`, `full_merged_other`
(`full.merged(with: other)`), `full_synced` (`syncSuspension(active:)`). `sidecar_info.json`:
per sidecar `{configKey, databaseCacheKey, databaseSummary, roundTripEqual (decode → encode
identical), estimatedStudyCounts, estimatedProgress, nextDue, laterLearningDues, dueTomorrow}`
at `timing`, and `syncSuspension {active, changed}`.

### `misc/*.otlog.jsonl`
`RevlogFile.encode` byte-exact: `revlog` (answers of the sidecar cards), `scheduler` (every
revlog of `scheduler/answers.json`), `revlog_unsorted_with_garbage` (input with bad lines) and
its `.decoded` re-encoding (`RevlogFile.decode` skips bad lines, sorts by id), `revlog_merged`
(`RevlogFile.merged`).

## Sizes
Total 16.5 MB on disk in 222 files (about 108 MB uncompressed; regenerated 2026-10-20).
No file exceeds 20 MB uncompressed (largest: `pgn/semislav.parse.json`, 12.9 MB), so no
summary/hash fallback is in use; the Semi-Slav dumps are kept in full.

| Folder | Files | On disk |
|---|---|---|
| `coverage/` | 120 | 6.5 MB |
| `inputs/` | 14 | 0.1 MB |
| `misc/` | 13 | 0.5 MB |
| `pgn/` | 28 | 1.4 MB |
| `queue/` | 1 | 1.8 MB |
| `scheduler/` | 2 | 0.4 MB |
| `session/` | 6 | 3.9 MB |
| `trainer/` | 6 | 1.1 MB |
| `tree/` | 30 | 0.7 MB |

Gzipped (27): `coverage/berlin.synthetic.black.json.gz`, `coverage/berlin.synthetic.white.json.gz`, `coverage/berlin.synthetic_missing.black.json.gz`, `coverage/berlin.synthetic_missing.white.json.gz`, `coverage/berlin.treestats.black.json.gz`, `coverage/berlin.treestats.white.json.gz`, `coverage/berlin.treestats_missing.black.json.gz`, `coverage/berlin.treestats_missing.white.json.gz`, `coverage/semislav.synthetic.black.json.gz`, `coverage/semislav.synthetic.white.json.gz`, `coverage/semislav.synthetic_missing.black.json.gz`, `coverage/semislav.synthetic_missing.white.json.gz`, `coverage/semislav.treestats.black.json.gz`, `coverage/semislav.treestats.white.json.gz`, `coverage/semislav.treestats_missing.black.json.gz`, `coverage/semislav.treestats_missing.white.json.gz`, `inputs/semislav.pgn.gz`, `pgn/semislav.parse.json.gz`, `pgn/semislav.written.pgn.gz`, `queue/queues.json.gz`, `scheduler/answers.json.gz`, `session/berlin.json.gz`, `session/semislav.json.gz`, `trainer/berlin.json.gz`, `trainer/semislav.json.gz`, `tree/berlin.tree.json.gz`, `tree/semislav.tree.json.gz`.
