#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) release app and packs it into a compressed disk image.
#
#   scripts/make-dmg.sh → build/release/Cybokron-Dock-Groups-<version>-universal.dmg
#   CODESIGN_IDENTITY=<SHA-1> scripts/make-dmg.sh → app and DMG signed with that identity
#
# The DMG holds the app and an Applications symlink. Without CODESIGN_IDENTITY the app is signed ad
# hoc by build-app.sh and the DMG isn't signed; with it, build-app.sh signs the app with that
# Developer ID identity and the DMG is signed with it too (ready for notarization).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Cybokron Dock Groups"
UNIVERSAL=1 scripts/build-app.sh release

APP="$ROOT/build/release/$APP_NAME.app"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
DMG="$ROOT/build/release/Cybokron-Dock-Groups-$VERSION-universal.dmg"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -format UDZO -ov "$DMG"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
    codesign --verify --strict "$DMG"
fi

echo "Built $DMG"
