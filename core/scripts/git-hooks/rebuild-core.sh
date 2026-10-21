#!/bin/zsh
# Rebuilds the xcframework when a merge, pull, checkout or rebase brought in changes to the
# library's sources. The xcframework is not committed, so it would otherwise stay older than
# the committed bindings and Xcode fails with "Cannot find 'uniffi_opening_core_checksum_…'".
# Usage: rebuild-core.sh <old commit> <new commit>  (called by the hooks in this folder)
# Set OT_SKIP_CORE_REBUILD=1 to skip it once.
set -euo pipefail

old="$1" new="$2"
[[ -n "${OT_SKIP_CORE_REBUILD:-}" ]] && exit 0
# A new clone or worktree: building every new worktree would take minutes, so leave it to
# whoever builds there (`core/scripts/build-apple.sh`).
[[ "$old" == 0000000000000000000000000000000000000000 ]] && exit 0
[[ "$old" == "$new" ]] && exit 0

repo_dir="$(git rev-parse --show-toplevel)"
if git diff --quiet "$old" "$new" -- \
  core/ot-core/src core/ot-ffi core/Cargo.toml core/Cargo.lock core/rust-toolchain.toml; then
  exit 0
fi

echo "Rust core changed: rebuilding the xcframework (OT_SKIP_CORE_REBUILD=1 skips this)"
if ! "$repo_dir/core/scripts/build-apple.sh"; then
  echo "core/scripts/build-apple.sh failed; run it again before building in Xcode" >&2
fi
