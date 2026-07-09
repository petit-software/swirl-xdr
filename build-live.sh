#!/bin/sh
# Build and launch SwirlLive.app — the fullscreen live-tuning companion app.
# Reuses SwirlCore.metal + SwirlRenderer.swift + SwirlSaverView.swift (for the
# shared settings keys) so it matches the screensaver exactly.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
APP="$BUILD/SwirlLive.app"
mkdir -p "$BUILD"

echo "Compiling shader -> metallib..."
xcrun -sdk macosx metal -O -c "$DIR/SwirlXDR/SwirlCore.metal" -o "$BUILD/SwirlCore.air"
xcrun -sdk macosx metallib "$BUILD/SwirlCore.air" -o "$BUILD/default.metallib"

echo "Assembling app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/default.metallib" "$APP/Contents/Resources/default.metallib"
cp "$DIR/SwirlLive/SwirlLive.icns" "$APP/Contents/Resources/SwirlLive.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SwirlLive</string>
    <key>CFBundleIdentifier</key><string>com.bartbak.SwirlLive</string>
    <key>CFBundleName</key><string>SwirlLive</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>SwirlLive</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key><string>1.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Compiling Swift..."
swiftc -O \
    "$DIR/SwirlLive/main.swift" \
    "$DIR/SwirlXDR/SwirlRenderer.swift" \
    "$DIR/SwirlXDR/SwirlSaverView.swift" \
    "$DIR/SwirlXDR/SwirlSettings.swift" \
    -framework AppKit -framework MetalKit -framework Metal -framework ScreenSaver \
    -o "$APP/Contents/MacOS/SwirlLive"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Launching $APP"
open "$APP"
