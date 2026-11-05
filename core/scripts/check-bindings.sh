#!/bin/zsh
# The commit hook's stand-in for build-apple.sh and build-android.sh: builds the core once, for
# this computer (debug), and from that one library
#   - refreshes the host library the Android and desktop JVM tests load (android/core/build/host),
#   - checks that the committed Swift and Kotlin bindings and both Acknowledgements.json files
#     match the sources.
# Minutes faster than building every platform's library, which the checks don't need: the app
# builds compile against the bindings. When something was out of date it is regenerated in place,
# listed, and the script exits 1 (review and stage it).
set -euo pipefail

export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"

core_dir="${0:A:h:h}"
repo_dir="${core_dir:h}"
fingerprint="$("$core_dir/scripts/core-fingerprint.sh")"

cd "$core_dir"
cargo build -q -p orbt-ffi
static=target/debug/libopening_core.a
dynamic=(target/debug/libopening_core.(dylib|so)(N))

# The JVM tests' library, stamped with the sources it was built from.
host="$repo_dir/android/core/build/host"
rm -rf "$host"
mkdir -p "$host"
cp $dynamic "$host/"
echo "$fingerprint" > "$host/sources"

work="$core_dir/target/check-bindings"
rm -rf "$work"
cargo run -q -p uniffi-bindgen-swift -- --swift-sources "$static" "$work/swift"
cargo run -q -p uniffi-bindgen -- generate --library --language kotlin --no-format \
  --out-dir "$work/kotlin" "${dynamic[1]}"

stale=()
compare() {  # generated, committed
  if ! cmp -s "$1" "$2"; then
    cp "$1" "$2"
    stale+=("${2#$repo_dir/}")
  fi
}
for generated in "$work/swift/"*.swift; do
  compare "$generated" "$repo_dir/apple/OpeningCoreRust/Sources/OpeningCoreRust/${generated:t}"
done
compare "$work/kotlin/org/orbtchess/orbt/core/opening_core.kt" \
  "$repo_dir/android/core/src/commonMain/kotlin/org/orbtchess/orbt/core/opening_core.kt"

"$core_dir/scripts/acknowledgements.py" --check >/dev/null 2>&1 \
  || { "$core_dir/scripts/acknowledgements.py"; stale+=(apple/ORBT/UI/Settings/Acknowledgements.json); }
"$core_dir/scripts/acknowledgements.py" --android --check >/dev/null 2>&1 \
  || { "$core_dir/scripts/acknowledgements.py" --android
       stale+=(android/app/src/commonMain/composeResources/files/Acknowledgements.json); }

if (( ${#stale} )); then
  echo "Out of date, now regenerated (review and stage them):" >&2
  printf '  %s\n' $stale >&2
  exit 1
fi
echo "bindings and acknowledgements up to date"
