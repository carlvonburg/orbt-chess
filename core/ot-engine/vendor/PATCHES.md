# Vendored Stockfish

Stockfish is GPL-3.0-or-later (`stockfish/Copying.txt`); credit the Stockfish developers
(`stockfish/AUTHORS`). The app is AGPL-3.0-or-later, which GPLv3 §13 allows to be combined
with it.

Both trees come from [lichess-org/dart-multistockfish](https://github.com/lichess-org/dart-multistockfish)
(GPL-3.0), commit `fd8dcea4fcbfd2ae936b409f8f329dded5d80a71`. They are upstream Stockfish's
`sf_19` release with lichess's patches already applied. We copied `src/` without `main.cpp`,
`universal/` and the `Makefile`.

| Directory | From | Contents |
| --- | --- | --- |
| `stockfish/` | `pkgs/multistockfish_chess/.../Stockfish` | `sf_19` plus the private-I/O patch (8 hunks in `misc.h`, `misc.cpp`, `uci.cpp`), in `namespace Stockfish`. Built with `NNUE_EMBEDDING_OFF`; the app downloads its net `nn-1a298aa575a0.nnue` (98,511,183 bytes). |
| `stockfish-light/` | `pkgs/multistockfish_light/.../StockfishLight` | The same, plus niklasf/Stockfish@81348d3 (the `p_hm` feature set for a 1.1 MB net), renamed to `namespace StockfishLight`. |
| `nnue/nn-61e7af4bb97d.nnue` | `pkgs/multistockfish_light/.../nnue` | The light net, compiled in with `.incbin` (so no LTO for these objects). |
| `sfio/` | `sfio.h`, `sfio.cpp` (identical in both packages) | The engine's private input and output streams. |
| `*/sfio_config.h` | the packages' `sfio_config.h` | The namespace each flavour's streams belong to. |

Our own code is `../bridge/bridge.cpp`, which mirrors upstream's `main.cpp` on descriptors it
is given, and `../build.rs`.

## Our change to the trees

There are none. One thing to keep in mind: the full flavour calls `exit()` when its net
fails to load (`Network::verify`). That would end the app, so `ot_engine::network_is_valid`
checks the file's SHA-256 against its name before the full flavour starts.

## Updating

1. Follow `UPDATING-io-patch.md` (the private-I/O patch) and `UPDATING-light.md` (light
   feature set, bench check, namespace rename). Both are copied from dart-multistockfish. An
   easier route is to take both trees from a dart-multistockfish release that has already
   moved to the new version.
2. Copy as described above, and update the commit here.
3. If the full net changes, update its name in the app's download list and `EvalFileDefaultName`.
4. Run `cargo test -p ot-engine`. It runs the light flavour for real.
