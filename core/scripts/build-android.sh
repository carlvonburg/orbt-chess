#!/bin/zsh
# Builds the Rust core for Android and the desktop JVM and refreshes the Kotlin bindings:
#   android/androidApp/src/main/jniLibs/<abi>/             (libopening_core.so + libc++_shared.so, not committed)
#   android/core/build/host/                               (the host's library, not committed)
#   android/core/src/commonMain/kotlin/.../opening_core.kt (generated Kotlin bindings, committed)
#   android/app/src/commonMain/composeResources/files/Acknowledgements.json
#                                                          (the licenses Settings shows, committed)
# The host's library serves the JVM tests (jna.library.path) and the desktop app: Gradle copies it
# into the app's resources for this OS and architecture (app/build.gradle.kts, `copyHostLibrary`,
# Compose's appResourcesRootDir: macos-arm64/, linux-x64/, windows-x64/), so `./gradlew :app:run`
# and the packaged app (`:app:packageDistributionForCurrentOS`) find it; Main.kt points JNA there.
# A package for Windows or Linux is built on that system, after this script.
# Usage: core/scripts/build-android.sh [--debug]
# Needs the Android NDK: $ANDROID_NDK_HOME, or the newest one in the Android SDK
# ($ANDROID_HOME, else ~/Library/Android/sdk).
set -euo pipefail

export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"

core_dir="${0:A:h:h}"
repo_dir="${core_dir:h}"
module_dir="$repo_dir/android/core"
# The Android app packages the core's .so files.
jni_dir="$repo_dir/android/androidApp/src/main/jniLibs"
lib_name="libopening_core.so"
# The app's minSdk.
api=29

profile="release"
cargo_flags=(--release)
if [[ "${1:-}" == "--debug" ]]; then
  profile="debug"
  cargo_flags=()
fi

sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ndk="${ANDROID_NDK_HOME:-}"
if [[ -z "$ndk" ]]; then
  ndk="$(ls -d "$sdk"/ndk/*(N) | sort -V | tail -1)"
fi
[[ -d "$ndk" ]] || { echo "no Android NDK found (set ANDROID_NDK_HOME)" >&2; exit 1; }
toolchain="$ndk/toolchains/llvm/prebuilt/darwin-x86_64"

# Rust target, Android ABI, clang's target triple.
abis=(
  "aarch64-linux-android arm64-v8a aarch64-linux-android"
  "x86_64-linux-android x86_64 x86_64-linux-android"
)

cd "$core_dir"
for entry in $abis; do
  read target abi triple <<< "$entry"
  echo "building $target ($profile)"
  env_target="${target//-/_}"
  upper="${(U)env_target}"
  export "CC_$env_target=$toolchain/bin/$triple$api-clang"
  export "CXX_$env_target=$toolchain/bin/$triple$api-clang++"
  export "AR_$env_target=$toolchain/bin/llvm-ar"
  export "CARGO_TARGET_${upper}_LINKER=$toolchain/bin/$triple$api-clang"
  # Stockfish is C++: link the NDK's shared libc++, shipped next to the core.
  CXXSTDLIB=c++_shared cargo build -q -p orbt-ffi --target "$target" $cargo_flags
  out="$jni_dir/$abi"
  rm -rf "$out"
  mkdir -p "$out"
  cp "target/$target/$profile/$lib_name" "$out/"
  cp "$toolchain/sysroot/usr/lib/$triple/libc++_shared.so" "$out/"
done

# The host's library: the JVM tests and the desktop app.
echo "building the host library ($profile)"
cargo build -q -p orbt-ffi $cargo_flags
host="$module_dir/build/host"
rm -rf "$host"
mkdir -p "$host"
cp target/$profile/libopening_core.(dylib|so)(N) "$host/"

# Bindings come from a library's metadata; they are the same for every target.
generated="$core_dir/target/kotlin"
rm -rf "$generated"
cargo run -q -p uniffi-bindgen -- generate --library --language kotlin --no-format \
  --out-dir "$generated" "target/aarch64-linux-android/$profile/$lib_name"
sources="$module_dir/src/commonMain/kotlin"
# Only the generated file: Additions.kt next to it is hand-written.
rm -f "$sources/org/orbtchess/orbt/core/opening_core.kt"
mkdir -p "$sources"
cp -R "$generated/" "$sources/"
echo "updated $module_dir and $jni_dir"

# The licenses of what the Android and desktop app ships.
python3 "$core_dir/scripts/acknowledgements.py" --android
