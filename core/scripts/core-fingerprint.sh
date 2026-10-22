#!/bin/zsh
# Prints a hash of the Rust sources the xcframework is built from (working tree contents,
# committed or not). build-apple.sh records it next to the xcframework, and the git hooks
# compare it to tell whether a worktree's xcframework is current or can be copied from another.
set -euo pipefail

cd "${0:A:h:h:h}"
git ls-files -z -co --exclude-standard -- \
  core/ot-core/src core/ot-engine core/ot-ffi core/Cargo.toml core/Cargo.lock core/rust-toolchain.toml \
  | sort -z | xargs -0 shasum | shasum | cut -d' ' -f1
