#!/bin/zsh
# Runs every fuzz target for $1 seconds (default 180) in parallel, seeding the corpora from
# the core's test data. Needs `rustup toolchain install nightly` and `cargo install cargo-fuzz`.
# Crashes land in artifacts/<target>/; replay one with `cargo +nightly fuzz run <target> <file>`.
set -u
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
cd "${0:A:h}"
secs=${1:-180}
data=../orbt-core/tests/data
mkdir -p corpus/{pgn,sidecar,revlog,explorer,uci,sync} logs
cp -n $data/pgn/* corpus/pgn/ 2>/dev/null
cp -n $data/sidecars/* corpus/sidecar/ 2>/dev/null
cp -n $data/revlog/* corpus/revlog/ 2>/dev/null
cp -n seeds/explorer/* corpus/explorer/ 2>/dev/null
cp -n seeds/uci/* corpus/uci/ 2>/dev/null
cp -n seeds/sync/* corpus/sync/ 2>/dev/null
cargo +nightly fuzz build -O || exit 1
for t in pgn sidecar revlog explorer uci sync; do
  cargo +nightly fuzz run -O $t -- -max_total_time=$secs -max_len=8192 > logs/$t.log 2>&1 &
done
wait
for t in pgn sidecar revlog explorer uci sync; do echo "== $t"; tail -3 logs/$t.log; done
