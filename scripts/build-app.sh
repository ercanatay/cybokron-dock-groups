#!/usr/bin/env bash
# Builds "Cybokron Dock Groups.app" with SwiftPM, without Xcode (the Command Line Tools suffice).
#
#   scripts/build-app.sh [debug|release]      → build/<configuration>/Cybokron Dock Groups.app
#   UNIVERSAL=1 scripts/build-app.sh release  → arm64 + x86_64 binary
#
# The Xcode project (project.yml / CybokronDockGroups.xcodeproj) is the primary build; this script
# mirrors its settings. Keep the version numbers below in sync with project.yml.
set -euo pipefail

CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in
    debug | release) ;;
    *) echo "usage: $0 [debug|release]" >&2; exit 64 ;;
esac

APP_NAME="Cybokron Dock Groups"
BUNDLE_ID="com.cybokron.dockgroups"
MARKETING_VERSION="3.0"
BUILD_NUMBER="1"
MINIMUM_MACOS="14.0"
PRODUCT="CybokronDockGroups"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/swiftpm-env.sh

APP="$ROOT/build/$CONFIGURATION/$APP_NAME.app"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

BUILD_ARGS=(-c "$CONFIGURATION" ${SWIFTPM_FLAGS[@]+"${SWIFTPM_FLAGS[@]}"})
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build --product "$PRODUCT" "${BUILD_ARGS[@]}"
BINARY="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/$PRODUCT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

PLIST="$APP/Contents/Info.plist"
cp Resources/Info.plist "$PLIST"
plutil -replace CFBundleExecutable -string "$APP_NAME" "$PLIST"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$PLIST"
plutil -replace CFBundleName -string "$APP_NAME" "$PLIST"
plutil -replace CFBundleShortVersionString -string "$MARKETING_VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"
plutil -replace LSMinimumSystemVersion -string "$MINIMUM_MACOS" "$PLIST"
if grep -q '\$(' "$PLIST"; then
    echo "error: unresolved build setting left in Info.plist" >&2
    exit 1
fi
plutil -lint "$PLIST" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The asset catalog compiler needs Xcode; build the .icns from the catalog's PNGs instead.
ICONSET="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
cp Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"

codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "Built $APP"
lipo -archs "$APP/Contents/MacOS/$APP_NAME"
