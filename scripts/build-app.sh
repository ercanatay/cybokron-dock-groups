#!/usr/bin/env bash
# Builds "Cybokron Dock Groups.app" with SwiftPM, without Xcode (the Command Line Tools suffice).
#
#   scripts/build-app.sh [debug|release]      → build/<configuration>/Cybokron Dock Groups.app
#   UNIVERSAL=1 scripts/build-app.sh release  → arm64 + x86_64 binary
#
# The Xcode project (project.yml / CybokronDockGroups.xcodeproj) is the primary build; this script
# mirrors its settings. Keep the version numbers below in sync with project.yml.
#
# With Xcode installed it also extracts the App Intents metadata (Contents/Resources/
# Metadata.appintents) through which Siri, Spotlight and the Shortcuts app find the app's actions,
# as Xcode's ExtractAppIntentsMetadata step does. The Command Line Tools lack that tool; their
# builds work, just without the actions in Shortcuts.
set -euo pipefail

CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in
    debug | release) ;;
    *) echo "usage: $0 [debug|release]" >&2; exit 64 ;;
esac

APP_NAME="Cybokron Dock Groups"
BUNDLE_ID="com.cybokron.dockgroups"
MARKETING_VERSION="0.5.0"
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
APPINTENTS_PROCESSOR="$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)"
# The swiftc driver of CI's Xcode 26.x rejects the const-values flags (only Xcode 27+ has them), so
# probe the driver instead of assuming.
swiftc_supports_const_gather() {
    local dir ok=1
    dir="$(mktemp -d)"
    printf 'import Foundation\nfunc probe() {}\n' > "$dir/probe.swift"
    xcrun swiftc -c "$dir/probe.swift" -o "$dir/probe.o" -emit-const-values \
        -const-gather-protocols-list "$ROOT/scripts/appintents-const-protocols.json" \
        >/dev/null 2>&1 || ok=0
    rm -rf "$dir"
    [[ "$ok" == 1 ]]
}
APPINTENTS_ENABLED=0
if [[ -n "$APPINTENTS_PROCESSOR" ]]; then
    if swiftc_supports_const_gather; then
        APPINTENTS_ENABLED=1
        # The compiler writes the constant values the metadata is extracted from (a .swiftconstvalues
        # file per source file). The protocol list's path must stay the same between builds, or
        # every build would recompile everything.
        BUILD_ARGS+=(-Xswiftc -emit-const-values -Xswiftc -const-gather-protocols-list
            -Xswiftc "$ROOT/scripts/appintents-const-protocols.json")
    else
        echo "App Intents metadata skipped: driver does not support const protocol gathering"
    fi
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

extract_app_intents_metadata() {
    local sources="$WORK_DIR/appintents-sources.txt" const_values="$WORK_DIR/appintents-constvalues.txt"
    local scratch="${SWIFTPM_SCRATCH_PATH:-$ROOT/.build}" marker="" file
    # SwiftPM's build systems name these files differently ("X.swiftconstvalues" next to the
    # objects, or "X.swift.swiftconstvalues"); the newest one for AppDelegate.swift marks the app
    # target's directory of the latest build.
    while IFS= read -r -d '' file; do
        if [[ -z "$marker" || "$file" -nt "$marker" ]]; then
            marker="$file"
        fi
    done < <(find "$scratch" \( -name 'AppDelegate.swiftconstvalues' -o -name 'AppDelegate.swift.swiftconstvalues' \) -print0)
    if [[ -z "$marker" ]]; then
        echo "error: the compiler wrote no .swiftconstvalues files under $scratch" >&2
        exit 1
    fi
    local directory
    directory="$(dirname "$marker")"
    : > "$sources"
    : > "$const_values"
    # Only files of current sources, so leftovers of deleted files don't count.
    while IFS= read -r -d '' file; do
        printf '%s\n' "$file" >> "$sources"
        local name
        name="$(basename "$file" .swift)"
        for candidate in "$directory/$name.swiftconstvalues" "$directory/$name.swift.swiftconstvalues"; do
            if [[ -f "$candidate" ]]; then
                printf '%s\n' "$candidate" >> "$const_values"
            fi
        done
    done < <(find "$ROOT/Sources/$PRODUCT" -name '*.swift' -print0)

    local arch
    case "$directory" in
        *arm64*) arch=arm64 ;;
        *x86_64*) arch=x86_64 ;;
        *) arch="$(uname -m)" ;;
    esac
    "$APPINTENTS_PROCESSOR" \
        --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
        --module-name "$PRODUCT" \
        --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
        --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
        --platform-family macOS \
        --deployment-target "$MINIMUM_MACOS" \
        --target-triple "$arch-apple-macos$MINIMUM_MACOS" \
        --source-file-list "$sources" \
        --swift-const-vals-list "$const_values" \
        --output "$APP/Contents/Resources" \
        --force
    if [[ ! -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]]; then
        echo "error: App Intents metadata extraction produced no Metadata.appintents" >&2
        exit 1
    fi
    echo "App Intents metadata: $APP/Contents/Resources/Metadata.appintents"
}
if [[ "$APPINTENTS_ENABLED" == 1 ]]; then
    extract_app_intents_metadata
elif [[ -z "$APPINTENTS_PROCESSOR" ]]; then
    echo "note: appintentsmetadataprocessor needs Xcode; Siri and Shortcuts won't list this build's actions." >&2
fi

codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "Built $APP"
lipo -archs "$APP/Contents/MacOS/$APP_NAME"
