#!/usr/bin/env bash
# Package Cortex.app into a styled "Drag to Install" .dmg.
#
# This is the layout used for the GitHub pre-releases: a window with the app icon,
# chevrons, and an Applications drop-link over a generated background (see
# scripts/dmg-background.swift). It produces an UNSIGNED, ad-hoc-signed .dmg.
#
# Why ad-hoc and not notarized: notarization needs a paid Apple Developer Program
# membership (Developer ID cert + notarytool). Without it, the .dmg still installs
# but Gatekeeper warns on first launch. Tell users to clear the quarantine flag once:
#     xattr -cr /Applications/Cortex.app
# For a "just works" signed build, see the staged steps in scripts/make-dmg.sh.
#
# Requirements: xcodegen, Xcode toolchain (swift/xcodebuild), and create-dmg
#     brew install create-dmg
#
# Usage: scripts/make-dmg-styled.sh [version]   (default version: dev)
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-dev}"
APP_NAME="Cortex"
BUILD_DIR="build"
SRC_DIR="$BUILD_DIR/dmg-src"
BG_PATH="$BUILD_DIR/dmg-background.png"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

command -v create-dmg >/dev/null 2>&1 || {
  echo "error: create-dmg not found. Install it with: brew install create-dmg" >&2
  exit 1
}

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building $APP_NAME (Release)"
rm -rf "$BUILD_DIR/DerivedData" "$SRC_DIR"
mkdir -p "$SRC_DIR"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  build
APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME.app"

echo "==> Ad-hoc signing (unsigned distribution; not notarized)"
codesign --force --deep --sign - "$APP_PATH"
cp -R "$APP_PATH" "$SRC_DIR/$APP_NAME.app"

echo "==> Rendering DMG background"
swift scripts/dmg-background.swift "$BG_PATH"

echo "==> Creating $DMG_PATH"
rm -f "$DMG_PATH"
create-dmg \
  --volname "$APP_NAME" \
  --background "$BG_PATH" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 120 \
  --icon "$APP_NAME.app" 165 200 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 495 200 \
  --no-internet-enable \
  "$DMG_PATH" "$SRC_DIR"

echo "==> Done: $DMG_PATH"
echo "    NOTE: this .dmg is UNSIGNED. On first launch users clear quarantine with:"
echo "          xattr -cr /Applications/$APP_NAME.app"
