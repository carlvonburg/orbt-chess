#!/bin/zsh
# The app target's "Release checks" build phase: a Release build (what Product › Archive makes)
# fails unless it has what a release needs, so one without them is never uploaded:
#   - the sync connectors' keys, from Secrets.xcconfig (apple/Config/ORBT.xcconfig says how);
#   - the Rust core's framework built for release from the core as it is now (build-apple.sh
#     records which in OpeningCoreFFI.sources; core-fingerprint.sh says what is now).
# Debug builds (Run, the simulator, the commit hook's build) skip it.
set -uo pipefail

[[ "${CONFIGURATION:-}" == Release ]] || exit 0

repo="${SRCROOT:?}/.."
problems=()
for key in ORBT_DROPBOX_APP_KEY ORBT_GOOGLE_IOS_CLIENT_ID ORBT_GOOGLE_REVERSED_CLIENT_ID; do
  [[ -n "${(P)key:-}" ]] || problems+=("$key is empty: add it to apple/Config/Secrets.xcconfig")
done

stamp="$repo/apple/OpeningCoreRust/OpeningCoreFFI.sources"
current="$("$repo/core/scripts/core-fingerprint.sh" 2>/dev/null)"
if [[ ! -f "$stamp" ]]; then
  problems+=("the core's framework has no release build record: run core/scripts/build-apple.sh")
elif [[ -z "$current" ]]; then
  problems+=("could not fingerprint the core (core/scripts/core-fingerprint.sh)")
elif [[ "$(<"$stamp")" != "$current" ]]; then
  problems+=("the core's framework is older than the core: run core/scripts/build-apple.sh")
fi

(( ${#problems} == 0 )) && exit 0
for problem in $problems; do echo "error: This release is not ready: $problem"; done
exit 1
