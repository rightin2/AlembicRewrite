#!/bin/bash
# Packages the release build into AlembicRewrite.app and installs to /Applications
set -e
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
swift build -c release
BIN=".build/release/AlembicRewrite"
BUNDLE_RES=$(dirname "$BIN")/AlembicRewrite_AlembicRewrite.bundle
APP="/Applications/AlembicRewrite.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AlembicRewrite"
# Bundle.module checks Bundle.main.resourceURL as well as the executable dir
cp -R "$BUNDLE_RES" "$APP/Contents/Resources/"
cp Sources/AlembicRewrite/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AlembicRewrite</string>
  <key>CFBundleIdentifier</key><string>com.alembic.rewrite</string>
  <key>CFBundleName</key><string>AlembicRewrite</string>
  <key>CFBundleDisplayName</key><string>AlembicRewrite</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign with a stable identifier so the Accessibility grant survives rebuilds
codesign --force --deep --sign - --identifier com.alembic.rewrite "$APP"
echo "Installed $APP (version $VERSION)"
