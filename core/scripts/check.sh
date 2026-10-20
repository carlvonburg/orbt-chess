#!/bin/zsh
# Everything CI checks for the Rust core: formatting, lints, tests, and that ot-core still
# builds for the web (wasm32), so a web shell stays possible.
set -euo pipefail

export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
cd "${0:A:h:h}"

cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo check -p ot-core --target wasm32-unknown-unknown
echo "core checks passed"
