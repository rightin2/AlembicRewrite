#!/bin/bash
# Builds AppIcon.icns from design/appicon-master.png (1024px+, square)
set -e
cd "$(dirname "$0")/.."
SRC="design/appicon-master.png"
[ -f "$SRC" ] || { echo "Missing $SRC — save the logo PNG there first."; exit 1; }
OUT="Sources/AlembicRewrite/Resources"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET" "$OUT"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz "$SRC" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  dbl=$((sz*2))
  sips -z $dbl $dbl "$SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"
echo "Wrote $OUT/AppIcon.icns"
