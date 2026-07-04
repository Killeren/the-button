#!/bin/bash
# Compile TheButton.app from Sources/main.swift (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

APP="TheButton.app"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"

swiftc -swift-version 5 -O \
    -o "$APP/Contents/MacOS/TheButton" \
    Sources/main.swift

# Ad-hoc sign so Accessibility permission survives rebuilds/moves.
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
