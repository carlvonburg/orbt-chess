#!/bin/zsh
# Every check for the Rust core: formatting, lints, tests, that orbt-core still builds for the
# web (wasm32), so a web shell stays possible, and cargo-deny (licenses, advisories, bans).
# The toolchain comes from rust-toolchain.toml.
set -euo pipefail

# rustup from Homebrew, and tools installed with `cargo install`.
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
cd "${0:A:h:h}"

if ! command -v cargo-deny >/dev/null; then
  echo "cargo-deny is not installed. Install it with: cargo install --locked cargo-deny" >&2
  exit 1
fi

cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo check -p orbt-core --target wasm32-unknown-unknown
cargo deny --log-level warn check
echo "core checks passed"
