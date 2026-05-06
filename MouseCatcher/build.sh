#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="MouseCatcher"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"

echo "==> Generating icon..."
mkdir -p "$ICONSET_DIR"
swift "$SCRIPT_DIR/generate_icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$SCRIPT_DIR/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_DIR")"

echo "==> Building $APP_NAME (universal)..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

# Per-arch compile + lipo so the helper matches ActiveSpace.app's
# universal build. Without -target, swiftc defaults to the host arch
# only, which historically shipped MouseCatcher as arm64-only on Apple
# Silicon dev machines — meaning Intel Mac users got a non-functional
# helper inside an otherwise-universal ActiveSpace.app.
MIN_MACOS=14.0
for ARCH in arm64 x86_64; do
    swiftc -O -target "$ARCH-apple-macos$MIN_MACOS" \
        -o "$APP_BUNDLE/Contents/MacOS/${APP_NAME}_$ARCH" \
        "$SCRIPT_DIR/main.swift" \
        -framework Cocoa
done
lipo -create \
    "$APP_BUNDLE/Contents/MacOS/${APP_NAME}_arm64" \
    "$APP_BUNDLE/Contents/MacOS/${APP_NAME}_x86_64" \
    -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
rm -f "$APP_BUNDLE/Contents/MacOS/${APP_NAME}_arm64" \
      "$APP_BUNDLE/Contents/MacOS/${APP_NAME}_x86_64"

cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$SCRIPT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

codesign --force --sign "Developer ID Application: Jonthan Hollin (EG86BCGUE7)" \
    --options runtime \
    --timestamp \
    "$APP_BUNDLE"

echo "==> Built: $APP_BUNDLE"
