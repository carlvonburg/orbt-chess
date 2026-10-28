#!/bin/sh
# Uploads website/public to Cloudflare Pages (project "orbtchess").
#   website/deploy.sh          production (orbtchess.org)
#   website/deploy.sh preview  a preview URL (preview.orbtchess.pages.dev), production untouched
# First time: see website/README.md (wrangler login, create the project).
set -eu

branch=main
if [ "${1:-}" = preview ]; then branch=preview; fi

cd "$(dirname "$0")"
npx --yes wrangler@4 pages deploy public \
    --project-name=orbtchess \
    --branch="$branch" \
    --commit-dirty=true
