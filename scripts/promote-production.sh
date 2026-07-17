#!/bin/bash
# Promote the current VERSION from staging to production: mark its GitHub
# pre-release as the latest stable release, and deploy the site to the
# Cloudflare Pages production (main) branch. Guarded by a confirm prompt.
set -e
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
TAG="v$VERSION"
REPO="rightin2/AlembicRewrite"

echo "About to PROMOTE AlembicRewrite $VERSION to production:"
echo "  - mark GitHub release $TAG as latest (removes pre-release flag)"
echo "  - deploy site to Cloudflare Pages production (main branch)"
read -r -p "Type 'promote' to continue: " CONFIRM
if [ "$CONFIRM" != "promote" ]; then
  echo "Aborted."
  exit 1
fi

# 1. Flip the pre-release to the latest stable release
gh release edit "$TAG" --repo "$REPO" --prerelease=false --latest

# 2. Cloudflare Pages production (main) branch
npx wrangler pages deploy site --project-name alembicrewrite --branch main

echo ""
echo "Promoted $VERSION to production:"
echo "  Release: https://github.com/$REPO/releases/tag/$TAG"
echo "  Site:    https://alembicrewrite.pages.dev"
