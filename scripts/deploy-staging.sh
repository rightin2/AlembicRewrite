#!/bin/bash
# Staging deploy: builds the DMG, publishes a GitHub PRE-release, and pushes the
# site to the Cloudflare Pages staging branch. Never touches the latest stable
# release or the production (main) branch.
set -e
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
TAG="v$VERSION"
DMG="dist/AlembicRewrite.dmg"
REPO="rightin2/AlembicRewrite"

# 1. Build the DMG fresh from source
./scripts/make-dmg.sh

# 2. GitHub pre-release for this version (create or update), with the DMG attached
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Updating existing pre-release $TAG"
  gh release edit "$TAG" --repo "$REPO" --prerelease
else
  echo "Creating pre-release $TAG"
  gh release create "$TAG" --repo "$REPO" --prerelease \
    --title "AlembicRewrite $VERSION" \
    --notes "Pre-release build of AlembicRewrite $VERSION for staging validation."
fi
gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber

# 3. Cloudflare Pages staging branch (does not affect production, which serves main)
npx wrangler pages deploy site --project-name alembicrewrite --branch staging

echo ""
echo "Staging deploy complete for $VERSION:"
echo "  Pre-release: https://github.com/$REPO/releases/tag/$TAG"
echo "  Site:        https://staging.alembicrewrite.pages.dev"
