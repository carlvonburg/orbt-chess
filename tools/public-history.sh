#!/bin/bash
# Builds the repository to publish: a fresh clone of one branch with the owner's private
# repertoires removed from every commit (testData/, the old core/fixtures copies and the
# snapshots made from them). This repository and its worktrees are left as they are.
#
# Usage: tools/public-history.sh [branch, default main] [output folder, default ../orbt-public]
# Needs git-filter-repo (brew install git-filter-repo). Push the result to the public remote.
set -euo pipefail

src=$(git rev-parse --show-toplevel)
branch=${1:-main}
out=$(cd "$src/.." && pwd)/orbt-public
out=${2:-$out}

git clone --quiet --no-local --single-branch --branch "$branch" "$src" "$out"
cd "$out"

# Old card-id snapshots listed the private Berlin's positions; the current one lists public ones.
current=$(git rev-parse "HEAD:core/orbt-core/tests/snapshots/snapshot_formats__card_ids.snap")
ids=$(mktemp)
git rev-list --objects HEAD | awk '/snapshot_formats__card_ids\.snap$/ { print $1 }' \
  | { grep -v "^$current$" || true; } | sort -u > "$ids"

git filter-repo --force --quiet --invert-paths \
  --path testData/ \
  --path-glob '*berlin*' --path-glob '*semislav*' \
  --path core/fixtures/misc/card_ids.json --path core/fixtures/queue/ \
  --strip-blobs-with-ids "$ids"
rm "$ids"
git gc --quiet --prune=now --aggressive

echo "Filtered $branch into $out ($(git rev-list --count HEAD) commits, $(du -sh .git | cut -f1))"
