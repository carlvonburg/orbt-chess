# Coverage tables: Classical (over-the-board) builder

Builds the app's Classical offline coverage tables (OTCB v2, read by
`core/ot-core/src/explorer/table.rs`) from Lumbra's Gigabase OTB, a PGN of ~12M games licensed
CC BY-NC 4.0: credit "Lumbra's Gigabase", no commercial use without a licence
(business@lumbrasgigabase.com). The Blitz and Rapid tables come from Lichess games; both kinds
share the format in `src/otcb.rs`.

Nothing here is committed output: PGNs and tables live in `data/` (ignored).

## Build
```
cargo build --release
target/release/tables <LumbrasGigabase_OTB.pgn> <out dir> <lichess tables dir (for evals)>
zstd -19 <out dir>/*.otcb
target/release/verify <out dir>/*.otcb.zst -- "e2e4" "d2d4"
```
About 100 s and 7.6 GB RAM for the full PGN. Then write the manifest with every table folder and
upload the tables and `manifest.json` to `coverage_bins/` on R2:
```
core/scripts/coverage-manifest.py <lichess tables dir> <otb tables dir>
```

## What `tables` does
- Games: standard start, classical over-the-board (no correspondence, no blitz/rapid by event name
  or a TimeControl base under 60 min), both players rated, played in 2000 or later, duplicates
  (same players, date, moves) dropped. Bins by average FIDE rating: 1400, 1600, 1800, 2000,
  2200 (to 2499), 2500+.
- Counts per move: the games that played the move in the position (as the Lichess explorer),
  over the first 70 plies.
- Walk, for both colours: every own move, opponent moves while p·share ≥ 1/N, stop where a
  position has fewer than 10 games (the app requires nothing there for Classical); files for
  N = 200 and 800 (the app downloads 800).
- Evals copied from the Lichess tables where they have the position.
- Prints the counts per filter step (the build report).

## Other tools
- `verify`: reads tables back and prints the moves of given lines.
- `dump`: per-move counts of given lines, summed over tables, as JSON lines.
- `headers`, `dates`, `levels`, `prefix`: analyses of the PGN's tags used to choose the filters.
- `scripts/`: `lichess_login.py` saves a Lichess token to `~/.config/opening-trainer/lichess_token`;
  `compare_masters.py` compares the tables with the Lichess masters explorer.
