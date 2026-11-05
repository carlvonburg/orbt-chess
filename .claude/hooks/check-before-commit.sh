#!/bin/zsh
# Claude Code PreToolUse hook (Bash): before a `git commit`, runs the checks for what the
# commit changes, and blocks the commit (exit 2) if one fails.
#   core/ changed            -> core/scripts/check.sh
#   the core's sources changed -> core/scripts/check-bindings.sh: one build for this computer
#                               checks the committed bindings and acknowledgements and refreshes
#                               the JVM tests' library; then both apps' checks below
#   apple/ (or the core) changed -> the iOS simulator build, against an xcframework with the
#                               current bindings (built only when none has them)
#   android/ (or the core) changed -> the JVM tests (bindings, app) and the Android app's Kotlin
#   apple/ORBT/UI/ changed -> no colors by name outside Palette.swift
#   android/app/src/*/ui/ changed -> no colors by name outside ui/theme
#   any PGN outside the test data and the store samples -> blocked (personal repertoires)
# Markdown files alone run no check. Other commands pass through untouched.
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
# Markdown (README, AGENTS.md, skills) changes no build: only the other files pick the checks.
code_changed=$(grep -vE '\.md$' <<<"$changed")
touches() { grep -qE "$1" <<<"$code_changed"; }

# Personal repertoires never go in the repo: PGNs only as test data and the store's samples.
pgns=$(grep -iE '\.pgn$' <<<"$changed" | grep -vE '^(core/orbt-core/tests/data|core/fuzz|Design/AppStore/samples)/' \
  | while read -r f; do [[ -e "$f" ]] && echo "$f"; done)
if [[ -n "$pgns" ]]; then
  echo "Commit blocked: PGN files outside the test data and the store samples (personal repertoires belong in testData/, which git ignores):" >&2
  echo "$pgns" >&2
  exit 2
fi

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
android_needed=false
touches '^apple/' && app_needed=true
touches '^android/' && android_needed=true
# What every platform's library is built from: one build for this computer checks it.
if touches '^core/(orbt-core|orbt-engine|orbt-ffi|uniffi-bindgen|uniffi-bindgen-swift)/|^core/(Cargo\.(toml|lock)|rust-toolchain\.toml)$'; then
  app_needed=true
  android_needed=true
  core/scripts/check-bindings.sh >>"$log" 2>&1 || fail "core/scripts/check-bindings.sh"
fi

if touches '^apple/ORBT/UI/'; then
  # Colors come from the roles in Palette.swift (Design/COLORS.md), never a hue by name.
  hues=$(grep -rnE '\.(red|green|blue|orange|yellow|purple|teal|mint|cyan|indigo|pink|brown)\b|Color\(red:|UIColor\(red:|NSColor\(red:' \
    apple/ORBT/UI --include='*.swift' | grep -v '/Palette.swift:')
  if [[ -n "$hues" ]]; then
    echo "Commit blocked: colors by name in the UI. Use a role from apple/ORBT/UI/Components/Palette.swift (see Design/COLORS.md):" >&2
    echo "$hues" >&2
    exit 2
  fi
fi

if touches '^android/app/src/.*/ui/'; then
  # The same rule on Android and the desktop: hues only in ui/theme (Design/COLORS.md).
  hues=$(grep -rnE 'Color\(0x|Color\((red|green|blue) *=|Color\.(Red|Green|Blue|Yellow|Cyan|Magenta|Gray|LightGray|DarkGray|Black|White)\b|Hues\.' \
    android/app/src --include='*.kt' | grep '/ui/' | grep -v '/ui/theme/')
  if [[ -n "$hues" ]]; then
    echo "Commit blocked: colors by name in the UI. Use a ThemeColor role or MaterialTheme.colorScheme (android/app/src/commonMain/kotlin/org/orbtchess/orbt/ui/theme, Design/COLORS.md):" >&2
    echo "$hues" >&2
    exit 2
  fi
fi

if $app_needed; then
  # The xcframework is not committed. Compiling the app needs one with the current bindings,
  # not one of the current sources: a core change that leaves the bindings alone keeps it.
  package=apple/OpeningCoreRust
  bindings=$(shasum $package/Sources/OpeningCoreRust/opening_core.swift | cut -d' ' -f1)
  usable() {  # <checkout> (this one)
    [[ -d "$1/$package/OpeningCoreFFI.xcframework" ]] || return 1
    [[ "$(cat "$1/$package/OpeningCoreFFI.bindings" 2>/dev/null)" == "$bindings" ]] && return 0
    # Built from these very sources (before the bindings stamp existed): the same bindings.
    [[ "$(cat "$1/$package/OpeningCoreFFI.sources" 2>/dev/null)" == "$(core/scripts/core-fingerprint.sh)" ]] || return 1
    echo "$bindings" > "$1/$package/OpeningCoreFFI.bindings"
  }
  if ! usable .; then
    for other in $(git worktree list --porcelain | sed -n 's/^worktree //p'); do
      [[ "$other" == "$repo" ]] && continue
      [[ -d "$other/$package/OpeningCoreFFI.xcframework" && "$(cat "$other/$package/OpeningCoreFFI.bindings" 2>/dev/null)" == "$bindings" ]] || continue
      rm -rf $package/OpeningCoreFFI.xcframework
      cp -c -R "$other/$package/OpeningCoreFFI.xcframework" $package/ && echo "$bindings" > $package/OpeningCoreFFI.bindings \
        && echo "Copied an xcframework with these bindings from $other" >>"$log" && break
    done
  fi
  usable . || core/scripts/build-apple.sh >>"$log" 2>&1 || fail "core/scripts/build-apple.sh"
  # The checkout's own project, whatever it is called (its scheme has the same name).
  project=(apple/*.xcodeproj(N))
  [[ ${#project} -eq 1 ]] || { echo "no single Xcode project in apple/" >"$log"; fail "finding the Xcode project"; }
  xcodebuild -project "$project" -scheme "${project:t:r}" \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -quiet build \
    >>"$log" 2>&1 || fail "the iOS simulator build"
fi

if $android_needed; then
  # Needs the host library from build-android.sh (android/core/build/host), built from the
  # current sources: an older one fails the tests with UnsatisfiedLinkError.
  # Copied from another worktree when one has it, else built for this computer only.
  host_current() { [[ "$(cat android/core/build/host/sources 2>/dev/null)" == "$(core/scripts/core-fingerprint.sh)" ]]; }
  host_current || core/scripts/git-hooks/rebuild-core.sh 0000000000000000000000000000000000000000 HEAD >>"$log" 2>&1
  host_current || core/scripts/check-bindings.sh >>"$log" 2>&1 || fail "core/scripts/check-bindings.sh"
  (cd android && ./gradlew -q :core:jvmTest :app:desktopTest :androidApp:compileDebugKotlin) >>"$log" 2>&1 \
    || fail "the Android/desktop JVM tests or the Android app's build"
fi

rm -f "$log"
exit 0
