#!/bin/bash
# Packages AlembicRewrite.app into a distributable DMG at dist/AlembicRewrite.dmg
set -e
cd "$(dirname "$0")/.."

# Fresh app bundle straight from source
./scripts/make-app.sh

APP="/Applications/AlembicRewrite.app"
STAGE="$(mktemp -d)/AlembicRewrite"
mkdir -p "$STAGE" dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Safety check: no API keys or secrets may ship in the bundle
if grep -rq "sk-ant-api03\|sk-proj-" "$STAGE/AlembicRewrite.app" 2>/dev/null; then
  echo "ABORT: an API key was found inside the app bundle." >&2
  exit 1
fi

# First-run instructions for recipients (unsigned app)
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
AlembicRewrite - install notes

1. Drag AlembicRewrite.app into the Applications folder alongside it.
2. First launch: RIGHT-CLICK the app and choose "Open", then "Open" again.
   (The app is not notarized with Apple, so a normal double-click will be
   blocked the first time. Right-click > Open only needs doing once.)
3. The setup walkthrough will ask for:
   - Accessibility permission (needed to read your selected text)
   - Your own Anthropic or OpenAI API key (Settings > API Keys).
     Get one at https://console.anthropic.com or https://platform.openai.com
4. Select text anywhere, press Cmd+Shift+R, and it rewrites in place.
   Cmd+Shift+E opens the style palette.

Your API key and all data stay on your Mac. Nothing is sent anywhere
except your own direct API calls to the provider you configure.
TXT

rm -f dist/AlembicRewrite.dmg
hdiutil create -volname "AlembicRewrite" -srcfolder "$STAGE" -ov -format UDZO dist/AlembicRewrite.dmg >/dev/null
echo "Wrote dist/AlembicRewrite.dmg ($(du -h dist/AlembicRewrite.dmg | cut -f1))"
