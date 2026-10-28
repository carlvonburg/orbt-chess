#!/bin/zsh
# Builds the Rust core for Apple platforms and refreshes the OpeningCoreRust Swift package:
#   apple/OpeningCoreRust/OpeningCoreFFI.xcframework   (static libraries + C headers, not committed)
#   apple/OpeningCoreRust/Sources/OpeningCoreRust/      (generated Swift bindings, committed)
#   apple/OpeningCoreRust/OpeningCoreFFI.sources        (core-fingerprint.sh of a release build)
#   apple/ORBT/UI/Settings/Acknowledgements.json        (the linked crates' licenses, committed)
# Usage: core/scripts/build-apple.sh [--debug]
set -euo pipefail

export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"

core_dir="${0:A:h:h}"
repo_dir="${core_dir:h}"
package_dir="$repo_dir/apple/OpeningCoreRust"
lib_name="libopening_core.a"
ffi_module="opening_coreFFI"

profile="release"
cargo_flags=(--release)
if [[ "${1:-}" == "--debug" ]]; then
  profile="debug"
  cargo_flags=()
fi

targets=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin x86_64-apple-darwin)

# Removed first so a failed or half-done build is never taken as current or copied.
stamp="$package_dir/OpeningCoreFFI.sources"
rm -f "$stamp"
fingerprint="$("$core_dir/scripts/core-fingerprint.sh")"

cd "$core_dir"
for target in $targets; do
  echo "building $target ($profile)"
  IPHONEOS_DEPLOYMENT_TARGET=26.0 MACOSX_DEPLOYMENT_TARGET=26.0 \
    cargo build -q -p ot-ffi --target "$target" $cargo_flags
done

work="$core_dir/target/apple"
rm -rf "$work"
mkdir -p "$work/headers" "$work/macos"

# Bindings come from the host library's metadata; they are the same for every target.
cargo run -q -p uniffi-bindgen-swift -- --swift-sources --headers \
  "target/aarch64-apple-darwin/$profile/$lib_name" "$work/generated"
cargo run -q -p uniffi-bindgen-swift -- --modulemap --module-name "$ffi_module" \
  --modulemap-filename module.modulemap \
  "target/aarch64-apple-darwin/$profile/$lib_name" "$work/headers"
cp "$work/generated/"*.h "$work/headers/"

lipo -create \
  "target/aarch64-apple-darwin/$profile/$lib_name" \
  "target/x86_64-apple-darwin/$profile/$lib_name" \
  -output "$work/macos/$lib_name"

rm -rf "$package_dir/OpeningCoreFFI.xcframework"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-ios/$profile/$lib_name" -headers "$work/headers" \
  -library "target/aarch64-apple-ios-sim/$profile/$lib_name" -headers "$work/headers" \
  -library "$work/macos/$lib_name" -headers "$work/headers" \
  -output "$package_dir/OpeningCoreFFI.xcframework" >/dev/null

sources="$package_dir/Sources/OpeningCoreRust"
mkdir -p "$sources"
cp "$work/generated/"*.swift "$sources/"
"$core_dir/scripts/acknowledgements.py"
[[ "$profile" == release ]] && echo "$fingerprint" > "$stamp"
echo "updated $package_dir"
