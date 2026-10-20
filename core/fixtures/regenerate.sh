#!/bin/sh
# Regenerates the golden fixtures from the Swift core (deleted: run this from an old checkout, see README.md), then gzips every file over 1 MB
# (name.ext -> name.ext.gz; -n leaves out name and time, so reruns are byte-identical).
set -eu
fixtures=$(cd "$(dirname "$0")" && pwd)
cd "$fixtures/../../apple/OpeningCore"
OT_WRITE_GOLDENS=1 swift test --filter GoldenFixtureTests
cd "$fixtures"
# The dumper wrote plain files: drop the .gz copies they replace (also if now under 1 MB).
find . -type f -name '*.gz' | while read -r gz; do [ -f "${gz%.gz}" ] && rm "$gz"; done
find . -type f ! -name '*.gz' ! -name README.md ! -name regenerate.sh -size +1000000c -print0 \
    | xargs -0 -n 1 gzip -9 -n -f
du -sh "$fixtures"
