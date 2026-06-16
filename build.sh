#!/bin/bash
# Builds Pulse for Claude into a universal .app bundle and a release zip.
# Requirements: Xcode or Command Line Tools (swiftc). No other dependencies.
set -e
cd "$(dirname "$0")"

VERSION="1.0.2"
NAME="Pulse for Claude"
BUNDLE_ID="club.everydayai.pulse"
BUILD_DIR="build"
APP="$BUILD_DIR/$NAME.app"

# Use the system default toolchain even if a custom one is installed.
SWIFTC="env TOOLCHAINS= xcrun swiftc"

echo "[1/5] Compiling (arm64)..."
mkdir -p "$BUILD_DIR"
$SWIFTC -O -swift-version 5 -target arm64-apple-macos13.0 src/main.swift -o "$BUILD_DIR/pulse_arm64" \
  -framework AppKit -framework Security -framework ServiceManagement 2>&1

echo "[2/5] Compiling (x86_64)..."
if $SWIFTC -O -swift-version 5 -target x86_64-apple-macos13.0 src/main.swift -o "$BUILD_DIR/pulse_x86_64" \
  -framework AppKit -framework Security -framework ServiceManagement 2>/dev/null; then
  lipo -create -output "$BUILD_DIR/pulse_universal" "$BUILD_DIR/pulse_arm64" "$BUILD_DIR/pulse_x86_64"
else
  echo "    x86_64 build unavailable, shipping arm64 only"
  cp "$BUILD_DIR/pulse_arm64" "$BUILD_DIR/pulse_universal"
fi

echo "[3/5] Assembling app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/pulse_universal" "$APP/Contents/MacOS/Pulse for Claude"
chmod +x "$APP/Contents/MacOS/Pulse for Claude"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>Pulse for Claude</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License · Built with Claude · Everyday AI Club</string>
</dict>
PLIST
echo "</plist>" >> "$APP/Contents/Info.plist"

if [ -f "assets/AppIcon.icns" ]; then
  cp "assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "[4/5] Signing (ad-hoc)..."
codesign --force --deep -s - "$APP"

echo "[5/5] Zipping release..."
mkdir -p dist
rm -f "dist/Pulse-for-Claude-$VERSION.zip"
ditto -c -k --keepParent "$APP" "dist/Pulse-for-Claude-$VERSION.zip"

echo ""
echo "Done."
echo "  App: $APP"
echo "  Zip: dist/Pulse-for-Claude-$VERSION.zip"
