#!/usr/bin/env bash
# Renders the app icon (Scripts/make-icon.swift) and packs every Mac size into App/Zapmirror/AppIcon.icns.
# Also keeps the 1024 px master at App/Support/AppIcon-1024.png.
#   Scripts/make-icon.sh
set -euo pipefail
source "$(dirname "$0")/config.sh"

WORK=$(mktemp -d /tmp/zapmirror-icon.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
MASTER="$WORK/master.png"
swift "$ROOT_DIR/Scripts/make-icon.swift" "$MASTER"

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$MASTER" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$MASTER" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT_DIR/App/Zapmirror/AppIcon.icns"
cp "$MASTER" "$ROOT_DIR/App/Support/AppIcon-1024.png"
echo "Wrote App/Zapmirror/AppIcon.icns and App/Support/AppIcon-1024.png"
