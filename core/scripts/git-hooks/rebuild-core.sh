#!/bin/zsh
# Keeps a worktree's xcframework (not committed) in step with its Rust sources, so it never
# lags the committed bindings and Xcode never fails with "Cannot find
# 'uniffi_opening_core_checksum_…'". When another worktree has a release build of exactly
# these sources, its xcframework is copied (a second); otherwise it is rebuilt (minutes).
# A new clone or worktree only copies; it is never built from here. A new worktree also starts
# with the main checkout's caches (see below), and the Android host library is copied the same way.
# Usage: rebuild-core.sh <old commit> <new commit>  (called by the hooks in this folder)
# Set ORBT_SKIP_CORE_REBUILD=1 to skip it once.
set -euo pipefail

old="$1" new="$2"
[[ -n "${ORBT_SKIP_CORE_REBUILD:-}" ]] && exit 0

repo_dir="$(git rev-parse --show-toplevel)"
package="apple/OpeningCoreRust"
fingerprint="$("$repo_dir/core/scripts/core-fingerprint.sh")"
main_dir="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"

# A new worktree starts from the main checkout's caches, so its first checks don't build from
# scratch: Android's local settings (the SDK's path, the Dropbox key; never committed), and a
# copy-on-write clone of the Rust build folder (APFS: seconds, no extra disk until it diverges;
# the dependencies stay built and only the workspace's own crates rebuild).
if [[ "$old" == 0000000000000000000000000000000000000000 && "$main_dir" != "$repo_dir" ]]; then
  settings=android/local.properties
  [[ -e "$main_dir/$settings" && ! -e "$repo_dir/$settings" ]] && cp "$main_dir/$settings" "$repo_dir/$settings"
  if [[ -d "$main_dir/core/target" && ! -e "$repo_dir/core/target" ]]; then
    cp -c -R "$main_dir/core/target" "$repo_dir/core/target" 2>/dev/null \
      && echo "Cloned the Rust build folder from $main_dir" || rm -rf "$repo_dir/core/target"
  fi
fi

# The Android host library (JVM tests, desktop app) of exactly these sources, from another worktree.
host=android/core/build/host
if [[ "$(cat "$repo_dir/$host/sources" 2>/dev/null)" != "$fingerprint" ]]; then
  git worktree list --porcelain | sed -n 's/^worktree //p' | while read -r other; do
    [[ "$other" == "$repo_dir" ]] && continue
    [[ "$(cat "$other/$host/sources" 2>/dev/null)" == "$fingerprint" ]] || continue
    rm -rf "$repo_dir/$host" && mkdir -p "$repo_dir/${host:h}" && cp -c -R "$other/$host" "$repo_dir/$host" \
      && echo "Copied the Android host library from $other" && break
  done
fi

[[ "$(cat "$repo_dir/$package/OpeningCoreFFI.sources" 2>/dev/null)" == "$fingerprint" ]] && exit 0

copy_from_other_worktree() {
  local other
  git worktree list --porcelain | sed -n 's/^worktree //p' | while read -r other; do
    [[ "$other" == "$repo_dir" ]] && continue
    [[ "$(cat "$other/$package/OpeningCoreFFI.sources" 2>/dev/null)" == "$fingerprint" ]] || continue
    local tmp="$repo_dir/$package/OpeningCoreFFI.xcframework.copying"
    rm -rf "$tmp" "$repo_dir/$package/OpeningCoreFFI.sources"
    cp -c -R "$other/$package/OpeningCoreFFI.xcframework" "$tmp" || continue
    # The other worktree may have started a build while we copied.
    [[ "$(cat "$other/$package/OpeningCoreFFI.sources" 2>/dev/null)" == "$fingerprint" ]] || { rm -rf "$tmp"; continue; }
    rm -rf "$repo_dir/$package/OpeningCoreFFI.xcframework"
    mv "$tmp" "$repo_dir/$package/OpeningCoreFFI.xcframework"
    echo "$fingerprint" > "$repo_dir/$package/OpeningCoreFFI.sources"
    echo "Copied the xcframework from $other"
    return 0
  done
  return 1
}

if [[ "$old" == 0000000000000000000000000000000000000000 ]]; then
  copy_from_other_worktree \
    || echo "No worktree has an xcframework of these sources: run core/scripts/build-apple.sh before building in Xcode"
  exit 0
fi
[[ "$old" == "$new" ]] && exit 0
if git diff --quiet "$old" "$new" -- \
  core/orbt-core/src core/orbt-engine core/orbt-ffi core/Cargo.toml core/Cargo.lock core/rust-toolchain.toml; then
  exit 0
fi

copy_from_other_worktree && exit 0
echo "Rust core changed: rebuilding the xcframework (ORBT_SKIP_CORE_REBUILD=1 skips this)"
if ! "$repo_dir/core/scripts/build-apple.sh"; then
  echo "core/scripts/build-apple.sh failed; run it again before building in Xcode" >&2
fi
