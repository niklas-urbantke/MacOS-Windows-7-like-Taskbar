#!/bin/bash
# Baut Win7Taskbar als macOS-.app-Bundle (Agent-App ohne Dock-Icon).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Win7Taskbar"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"

echo "▶ Release-Build…"
swift build -c release

echo "▶ App-Bundle zusammenbauen…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Orb-Bilder aus dem Ordner "orbs/" einbinden (Auswahl im Einstellfenster).
if [ -d "orbs" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/orbs"
    cp orbs/*.png "$APP_BUNDLE/Contents/Resources/orbs/" 2>/dev/null
    echo "▶ Orbs eingebunden: $(ls orbs/*.png 2>/dev/null | xargs -n1 basename | paste -sd ', ' -)"
fi

# Original-Windows-7-Theme-Grafiken (Leiste, Buttons, Orb, Show-Desktop …).
if [ -d "ThemeResources" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/theme"
    cp ThemeResources/*.png "$APP_BUNDLE/Contents/Resources/theme/" 2>/dev/null
    echo "▶ Win7-Theme-Grafiken eingebunden: $(ls ThemeResources/*.png 2>/dev/null | wc -l | tr -d ' ') PNGs."
fi

# MediaRemote-Helfer: systemweite Wiedergabe-Info (Tidal & Co.). Die dylib läuft in
# /usr/bin/perl, weil macOS die Info normalen Apps vorenthält (siehe MediaRemoteHelper/).
if [ -d "MediaRemoteHelper" ]; then
    MR_OUT=".build/mediaremote"
    mkdir -p "$MR_OUT" "$APP_BUNDLE/Contents/Resources/mediaremote"
    if clang -dynamiclib -fobjc-arc -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
            -framework Foundation -o "$MR_OUT/libmediaremote-helper.dylib" \
            MediaRemoteHelper/MediaRemoteHelper.m; then
        cp "$MR_OUT/libmediaremote-helper.dylib" MediaRemoteHelper/mediaremote-helper.pl \
            "$APP_BUNDLE/Contents/Resources/mediaremote/"
        # Beide Architekturen einzeln signieren (ld signiert nur arm64), sonst stolpert
        # das Signieren des Bundles über ungesignierten Code in den Resources.
        codesign --force --sign - "$APP_BUNDLE/Contents/Resources/mediaremote/libmediaremote-helper.dylib" \
            >/dev/null 2>&1 || true
        echo "▶ MediaRemote-Helfer eingebunden (arm64 + x86_64)."
    else
        echo "⚠ MediaRemote-Helfer nicht gebaut: Medienanzeige nur für Spotify/Music."
    fi
fi

# Build-Commit einbacken, damit die App ihren eigenen Stand kennt (für das Self-Update).
GIT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>Windows 7 Taskleiste</string>
    <key>CFBundleIdentifier</key>      <string>de.batix.win7taskbar</string>
    <key>CFBundleVersion</key>         <string>4.1.0</string>
    <key>CFBundleShortVersionString</key><string>4.1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Zeigt deine Termine im Kalender der Taskleiste an (nur lesend).</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Steuert Musik-Player, Finder, Energie-Aktionen und die DockDoor-Fenstervorschau.</string>
    <key>GitCommit</key>               <string>$GIT_COMMIT</string>
</dict>
</plist>
PLIST

# Signieren: stabile Identität nutzen falls vorhanden (siehe setup-signing.sh),
# sonst ad-hoc. Stabile Signatur = erteilte Berechtigungen bleiben über Rebuilds erhalten.
IDENTITY="Win7Taskbar Self-Signed"
# Hash der GÜLTIGEN Identität (ohne "Invalid"-Hinweis, falls mehrere existieren).
HASH=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "$IDENTITY" | grep -v -i "invalid" | head -1 | awk '{print $2}' || true)
if [ -n "$HASH" ]; then
    codesign --force --deep --sign "$HASH" "$APP_BUNDLE" >/dev/null 2>&1 \
        && echo "▶ Stabil signiert ($IDENTITY) – Berechtigungen bleiben erhalten." \
        || { codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1; echo "⚠ Stabiles Signieren fehlgeschlagen → ad-hoc."; }
else
    codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
    echo "ℹ Ad-hoc signiert. Tipp: einmal ./setup-signing.sh ausführen."
fi

echo "✔ Fertig: $(pwd)/$APP_BUNDLE"
echo "   Starten:  open \"$APP_BUNDLE\"   (oder Doppelklick im Finder)"
