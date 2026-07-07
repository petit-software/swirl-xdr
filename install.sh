#!/bin/sh
# Build (if needed) and install SwirlSaver into ~/Library/Screen Savers,
# then reset the screensaver host so the new build is picked up cleanly.
set -e

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Screen Savers"

# Always build (incremental) so source changes are never skipped.
echo "Building..."
xcodebuild -project "$PROJ_DIR/SwirlXDR.xcodeproj" -scheme SwirlXDR -configuration Release build

SAVER="$(xcodebuild -project "$PROJ_DIR/SwirlXDR.xcodeproj" -scheme SwirlXDR \
    -configuration Release -showBuildSettings 2>/dev/null \
    | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} END{print d"/Swirl XDR.saver"}')"

mkdir -p "$DEST"
rm -rf "$DEST/SwirlSaver.saver" "$DEST/Swirl XDR.saver"   # remove old + prior name
cp -R "$SAVER" "$DEST/"
killall legacyScreenSaver 2>/dev/null || true
killall ScreenSaverEngine 2>/dev/null || true
echo "Installed: $DEST/Swirl XDR.saver"
echo "Open System Settings > Screen Saver > Swirl XDR."
