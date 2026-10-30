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
fails to load (`Network::verify`). That would end the app, so `orbt_engine::network_is_valid`
checks the file's SHA-256 against its name before the full flavour starts.

## Android arm64: two copies, chosen at run time

Android cannot ship a library per CPU feature, and phones before ARMv8.2 (Cortex-A53, A73)
lack the dot product that speeds up the nets' layers. So on
`aarch64-linux-android` `build.rs` compiles each flavour twice, Stockfish's `armv8` and
`armv8-dotprod`, and `Simd::current` in `src/lib.rs` starts the dot product copy only when
`getauxval(AT_HWCAP)` has `HWCAP_ASIMDDP`. This is upstream's `arm64-universal` build
(Stockfish's `src/universal/entry_arm64.cpp` and section 6 of its `Makefile`, both in
dart-multistockfish's trees at the commit above, not copied here), done without LTO:

- The second copy is compiled with `-DStockfish=StockfishDotprod
  -DStockfishLight=StockfishLightDotprod` (upstream: `-DStockfish=Stockfish_<arch>`) and its own
  entry point (`orbt_sf_light_dotprod_main`, `orbt_sf_full_dotprod_main`).
- Its objects are linked into one (`ld.lld -r`), then `llvm-objcopy` removes the COMDAT groups
  and makes every symbol local but the entry point, so the C++ library templates both copies
  instantiate are never shared: the baseline never calls code compiled for ARMv8.2 (upstream:
  `objcopy -R .group`, with LTO making the symbols local).
- Its `.init_array` is renamed `orbt_sf_<flavour>_dotprod_init` (upstream: `<arch>_init`), so
  its static initializers do not run when the library loads on every phone; `bridge.cpp` runs
  them once, through `__start_`/`__stop_`, before the copy's first start.
- The light copy defines `UNIVERSAL_BINARY`, which makes `nnue/network.cpp` declare the
  baseline's `gEmbeddedNNUEData` instead of embedding the net a second time.

None of this touches the trees. The arm64 library grows by about 0.9 MB stripped (5.5 to 6.4
MB). On the arm64 emulator (an Apple M-series core) the light flavour's dot product copy
searches about 18% more nodes per second than the baseline (2.4 against 2.0 million, one
thread), and both copies search the same tree (`both_arm64_copies_search_the_same_tree`, which
runs only on a device).

## Updating

1. Follow `UPDATING-io-patch.md` (the private-I/O patch) and `UPDATING-light.md` (light
   feature set, bench check, namespace rename). Both are copied from dart-multistockfish. An
   easier route is to take both trees from a dart-multistockfish release that has already
   moved to the new version.
2. Copy as described above, and update the commit here.
3. If the full net changes, update its name in the app's download list and `EvalFileDefaultName`.
4. Run `cargo test -p orbt-engine`. It runs the light flavour for real.
5. If `network.cpp` no longer reads `UNIVERSAL_BINARY`, or new names outside the namespaces
   need to be shared between the copies, update `dotprod_copy` in `build.rs`. Then run the unit
   tests on an arm64 phone or emulator: build them with the NDK as `scripts/build-android.sh`
   sets it up (`cargo test --release -p orbt-engine --target aarch64-linux-android --no-run`),
   `adb push` the `orbt_engine-*` test binary and `libc++_shared.so` to `/data/local/tmp`, and run
   it there with `LD_LIBRARY_PATH=.`.
