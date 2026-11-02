#!/bin/bash
# Build a styled, signed DMG for distributing Beacon.
#
# Usage: Scripts/make-dmg.sh /path/to/Beacon.app [output.dmg]
#
# Expects the .app to already be Developer ID signed (release.sh exports it
# that way). The background comes from Scripts/dmg-bg.png and dmg-bg@2x.png;
# regenerate them with render-dmg-background.swift if the branding changes.
set -euo pipefail

APP="${1:?Usage: make-dmg.sh /path/to/Beacon.app [output.dmg]}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
command -v create-dmg >/dev/null || { echo "create-dmg not installed (brew install create-dmg)" >&2; exit 1; }

# Sign the DMG only with a Developer ID from the same team as the app inside;
# a wrapper signed by a different team confuses notarization.
APP_TEAM=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
SIGN_ID=$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: [^\"]*($APP_TEAM)\)\".*/\1/p" | head -1)

VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "1.0")
OUT="${2:-$HOME/Desktop/Beacon-$VERSION.dmg}"

# Stage the app in a clean folder so the DMG contains only Beacon.app, and
# combine the background PNGs into one HiDPI TIFF for Finder.
STAGING=$(mktemp -d)
WORK=$(mktemp -d)
trap 'rm -rf "$STAGING" "$WORK"' EXIT
cp -R "$APP" "$STAGING/"
tiffutil -cathidpicheck "$SCRIPT_DIR/dmg-bg.png" "$SCRIPT_DIR/dmg-bg@2x.png" -out "$WORK/dmg-bg.tiff" 2>/dev/null

rm -f "$OUT"
create-dmg \
  --volname "Beacon" \
  --volicon "$APP/Contents/Resources/AppIcon.icns" \
  --background "$WORK/dmg-bg.tiff" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 110 \
  --icon "Beacon.app" 150 200 \
  --hide-extension "Beacon.app" \
  --app-drop-link 450 200 \
  "$OUT" \
  "$STAGING"

if [ -n "$SIGN_ID" ]; then
  codesign --force --timestamp --sign "$SIGN_ID" "$OUT"
  echo "DMG signed with: $SIGN_ID"
else
  echo "No local Developer ID certificate for team $APP_TEAM; DMG left unsigned."
fi
echo
echo "Created: $OUT"
