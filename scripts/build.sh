#!/usr/bin/env bash
# Build Cortex from the command line. Regenerates the Xcode project from project.yml
# (the source of truth, the .xcodeproj is not committed) and builds it.
#
# Usage: scripts/build.sh [Debug|Release]   (default: Debug)
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

CONFIGURATION="${1:-Debug}"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building Cortex ($CONFIGURATION)"
xcodebuild -project Cortex.xcodeproj -scheme Cortex \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  build

echo "==> Done."
echo "    App: ~/Library/Developer/Xcode/DerivedData/Cortex-*/Build/Products/$CONFIGURATION/Cortex.app"
