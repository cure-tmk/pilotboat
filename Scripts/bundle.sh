#!/usr/bin/env bash
# Builds Pilotboat.app from `swift build` output (no Xcode project needed).
# Usage: Scripts/bundle.sh [debug|release]   → .build/Pilotboat.app
# Set PILOTBOAT_SIGN_IDENTITY to a stable code-signing identity to avoid Keychain prompts on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
VERSION="${PILOTBOAT_VERSION:-0.1.0}"
BUILD_DIR=$(swift build -c "$CONFIG" --show-bin-path)
swift build -c "$CONFIG" --product Pilotboat
APP=".build/Pilotboat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/Pilotboat" "$APP/Contents/MacOS/Pilotboat"
if [ -d "$BUILD_DIR/Pilotboat_Pilotboat.bundle" ]; then
  cp -R "$BUILD_DIR/Pilotboat_Pilotboat.bundle" "$APP/Contents/Resources/"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Pilotboat</string>
  <key>CFBundleIdentifier</key><string>io.github.cure-tmk.pilotboat</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Pilotboat</string>
  <key>CFBundleDisplayName</key><string>Pilotboat</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ja</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST
codesign --force --sign "${PILOTBOAT_SIGN_IDENTITY:--}" "$APP" >/dev/null
echo "$APP"
