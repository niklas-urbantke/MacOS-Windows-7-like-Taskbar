#!/bin/bash
# Baut Win7Taskbar.app (Release) und verpackt es als DMG für die Weitergabe.
set -euo pipefail
cd "$(dirname "$0")"

APP="Win7Taskbar.app"
VOL="Win7 Taskbar"
DMG="Win7Taskbar.dmg"

echo "▶ App bauen…"
./build.sh

echo "▶ DMG-Inhalt vorbereiten…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"          # Drag-to-install

echo "▶ DMG erzeugen…"
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

SIZE=$(du -h "$DMG" | cut -f1)
echo "✔ Fertig: $(pwd)/$DMG ($SIZE)"
