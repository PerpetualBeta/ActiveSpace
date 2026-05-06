#!/bin/bash
# Build SwitchHelper as a universal Mach-O. The Xcode project references
# the resulting binary as a Resources file (just copied into the bundle,
# not re-compiled), so we have to keep this universal manually whenever
# main.swift changes.
#
# Outputs: SwitchHelper/switch_helper (this directory, source-of-truth)
#          ActiveSpace/switch_helper (the path the Xcode project copies)
#
# Run from anywhere; the script resolves its own location.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
NAME="switch_helper"
MIN_MACOS=14.0

echo "==> Building $NAME (universal)..."
cd "$SCRIPT_DIR"

for ARCH in arm64 x86_64; do
    swiftc -O -target "$ARCH-apple-macos$MIN_MACOS" \
        -o "${NAME}_$ARCH" \
        main.swift
done
lipo -create "${NAME}_arm64" "${NAME}_x86_64" -output "$NAME"
rm -f "${NAME}_arm64" "${NAME}_x86_64"

# Mirror to the location the Xcode project picks up.
cp "$NAME" "$PROJECT_DIR/ActiveSpace/$NAME"

echo "==> Built: $SCRIPT_DIR/$NAME"
file "$NAME"
