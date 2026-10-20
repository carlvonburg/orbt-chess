# Deviations

Where the Rust core differs from the Swift OpeningCore it replaces, or from the established
source it follows (Anki, fsrs-rs, lichess's crates). Each entry says why.

## From the Swift OpeningCore

- **FSRS from the fsrs crate (f32), not the Swift copy (f64).** Anki itself calls
  `fsrs::FSRS::next_states`, so this is closer to Anki. Memory states differ from the Swift
  build around the 6th significant digit; they are written as the shortest decimal of the
  f32 (`2.3065`, not `2.306499958038330`). An interval that lands exactly on .5 days could
  round differently.
- **Filtered-deck order.** The Swift build shuffled with Swift's `shuffle(using:)`; this uses
  Fisher-Yates over the same SplitMix64 seed, so the order differs. Anki orders filtered decks
  randomly too.
- **Deterministic tie-breaks.** Where Swift iterated a `Set` or `Dictionary` (pending
  positions with equal reach, intraday learning cards with equal due and reps, transposition
  propagation order), ties are broken by EPD or node id. Results only differ among equals.
- **Tree nodes keep their position** instead of a FEN string that is re-parsed on every
  access. `RepertoireNode::fen()` produces the same FEN.

## From the established libraries

- **PGN: our parser and writer, not pgn-reader.** The Swift parser's comment placement
  (comments right after "(" become pre-comments of the variation's first move, `%` escape
  lines, `!?` glyphs as NAGs) and the writer's exact output are the file format: re-saving
  must not reformat a user's repertoire. pgn-reader attaches comments differently. Chess
  rules still come from shakmaty, by the same author.
- **Fuzz RNG: SplitMix64, not Anki's ChaCha12 (`StdRng`).** Same seed (card id + reps) and
  the same ranges, so intervals are fuzzed like Anki's, but the chosen day can differ. Kept
  from the Swift build so existing schedules stay reproducible.
- **Day numbers from a fixed epoch (1 Jan 2020 local time)**, not the collection's creation,
  so every device and repertoire agrees. The platform computes them, as Anki takes the UTC
  offset from its caller.
