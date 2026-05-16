#!/bin/bash
# VirtualDisplayHost build script. Mirrors MouseCatcher/build.sh's
# universal-binary + Developer ID signing pattern — see comments there
# for the rationale on per-arch compile + lipo (Apple-Silicon-only ship
# vs. Intel users with non-functional helpers).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="VirtualDisplayHost"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"

echo "==> Building $APP_NAME (universal)..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"

MIN_MACOS=14.0
for ARCH in arm64 x86_64; do
    clang -fobjc-arc -O \
        -target "$ARCH-apple-macos$MIN_MACOS" \
        -framework Foundation -framework AppKit \
        -framework CoreGraphics -framework ApplicationServices \
        -o "$APP_BUNDLE/Contents/MacOS/${APP_NAME}_$ARCH" \
        "$SCRIPT_DIR/main.m"
done
lipo -create \
    "$APP_BUNDLE/Contents/MacOS/${APP_NAME}_arm64" \
    "$APP_BUNDLE/Contents/MacOS/${APP_NAME}_x86_64" \
    -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
rm -f "$APP_BUNDLE/Contents/MacOS/${APP_NAME}_arm64" \
      "$APP_BUNDLE/Contents/MacOS/${APP_NAME}_x86_64"

cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

codesign --force --sign "Developer ID Application: Jonthan Hollin (EG86BCGUE7)" \
    --options runtime \
    --timestamp \
    "$APP_BUNDLE"

echo "==> Built: $APP_BUNDLE"
