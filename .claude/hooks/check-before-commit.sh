#!/bin/zsh
# Claude Code PreToolUse hook (Bash): before a `git commit`, runs the checks for what the
# commit changes, and blocks the commit (exit 2) if one fails.
#   core/ changed            -> core/scripts/check.sh
#   core/ot-ffi/ or Cargo.lock changed -> core/scripts/build-apple.sh; the committed Swift
#                               bindings must already be up to date
#   apple/ or the FFI changed -> the iOS simulator build
#   apple/openingTrainer/UI/ changed -> no colors by name outside Palette.swift
# Other commands pass through untouched.
set -uo pipefail

input=$(cat)
command=$(jq -r '.tool_input.command // ""' <<<"$input")
[[ "$command" =~ 'git( -C [^ ]+)? commit' ]] || exit 0

cwd=$(jq -r '.cwd // ""' <<<"$input")
[[ -n "$cwd" ]] && cd "$cwd"
# `git -C <dir> commit` commits in <dir>.
if [[ "$command" =~ 'git -C ([^ ]+) commit' ]]; then
  cd "${~match[1]}" 2>/dev/null || true
fi
repo=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$repo"
[[ -x core/scripts/check.sh ]] || exit 0

# What the commit may contain: staged files, plus unstaged and untracked ones when the same
# command stages them (`git add … && git commit`, `git commit -a`).
changed=$(git diff --cached --name-only)
if [[ "$command" == *"git add"* || "$command" =~ 'commit +-[a-zA-Z]*a' ]]; then
  changed+=$'\n'$(git diff --name-only; git ls-files --others --exclude-standard)
fi
touches() { grep -qE "$1" <<<"$changed"; }

log=$(mktemp -t check-before-commit)
fail() {
  echo "Commit blocked: $1 failed. Fix it and commit again. Last lines of the output (full log: $log):" >&2
  tail -n 40 "$log" >&2
  exit 2
}

if touches '^core/'; then
  core/scripts/check.sh >"$log" 2>&1 || fail "core/scripts/check.sh"
fi

app_needed=false
touches '^apple/' && app_needed=true
if touches '^core/(ot-ffi/|Cargo\.lock)'; then
  app_needed=true
  bindings=apple/OpeningCoreRust/Sources/OpeningCoreRust/opening_core.swift
  before=$(shasum "$bindings" 2>/dev/null)
  core/scripts/build-apple.sh >>"$log" 2>&1 || fail "core/scripts/build-apple.sh"
  if [[ "$(shasum "$bindings" 2>/dev/null)" != "$before" ]]; then
    echo "Commit blocked: the Swift bindings were out of date. build-apple.sh has regenerated $bindings; review and stage it, then commit again." >&2
    exit 2
  fi
fi

if touches '^apple/openingTrainer/UI/'; then
  # Colors come from the roles in Palette.swift (Design/COLORS.md), never a hue by name.
  hues=$(grep -rnE '\.(red|green|blue|orange|yellow|purple|teal|mint|cyan|indigo|pink|brown)\b|Color\(red:|UIColor\(red:|NSColor\(red:' \
    apple/openingTrainer/UI --include='*.swift' | grep -v '/Palette.swift:')
  if [[ -n "$hues" ]]; then
    echo "Commit blocked: colors by name in the UI. Use a role from apple/openingTrainer/UI/Components/Palette.swift (see Design/COLORS.md):" >&2
    echo "$hues" >&2
    exit 2
  fi
fi

if $app_needed; then
  xcodebuild -project apple/openingTrainer.xcodeproj -scheme openingTrainer \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -quiet build \
    >>"$log" 2>&1 || fail "the iOS simulator build"
fi

rm -f "$log"
exit 0
