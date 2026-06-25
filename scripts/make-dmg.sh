#!/usr/bin/env bash
# Package Cortex.app into a distributable .dmg.
#
# Code signing and notarization are STAGED but commented out: they require an Apple
# Developer ID certificate and App Store Connect credentials. Until those are set up,
# this produces an UNSIGNED .dmg suitable for local use only. Uncomment and fill in the
# signing and notarization steps before distributing publicly.
#
# Usage: scripts/make-dmg.sh [Release|Debug]   (default: Release)
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Release}"
APP_NAME="Cortex"
BUILD_DIR="build"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building $APP_NAME ($CONFIGURATION)"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
xcodebuild -project Cortex.xcodeproj -scheme Cortex \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  build

cp -R "$BUILD_DIR/DerivedData/Build/Products/$CONFIGURATION/$APP_NAME.app" "$APP_PATH"

# --- Code signing (requires an Apple Developer ID) -------------------------------
# DEVELOPER_ID="Developer ID Application: YOUR NAME (TEAMID)"
# codesign --deep --force --options runtime --timestamp \
#   --sign "$DEVELOPER_ID" "$APP_PATH"

echo "==> Creating $DMG_PATH"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"

# --- Notarization (requires App Store Connect credentials) -----------------------
# xcrun notarytool submit "$DMG_PATH" \
#   --apple-id "you@example.com" --team-id "TEAMID" --password "APP_SPECIFIC_PASSWORD" \
#   --wait
# xcrun stapler staple "$DMG_PATH"

echo "==> Done: $DMG_PATH"
echo "    NOTE: this .dmg is UNSIGNED and for local use only until signing is configured."
