#!/usr/bin/env bash
# Builds NotchClaw.app (arm64, release) and a drag-to-install DMG.
#   scripts/build.sh            -> dist/NotchClaw.app + dist/NotchClaw-<version>.dmg
#   scripts/build.sh --desktop  -> also copies the DMG to ~/Desktop
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
DIST="$ROOT/dist"
APP="$DIST/NotchClaw.app"

# The macOS 27 SDK's SwiftUI needs a macro plugin that ships only with Xcode;
# the 26.x SDK in the Command Line Tools builds the same app without it.
if [[ -z "${SDKROOT:-}" ]]; then
  for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk; do
    [[ -d "$sdk" ]] && export SDKROOT="$sdk"
  done
fi

echo "==> Building NotchClaw $VERSION ($BUILD)"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/NotchClaw"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchClaw"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - --entitlements Resources/NotchClaw.entitlements --options runtime "$APP"
codesign --verify --strict "$APP"

echo "==> Creating DMG"
DMG="$DIST/NotchClaw-$VERSION.dmg"
STAGE="$DIST/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "NotchClaw $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "    $DMG"

if [[ "${1:-}" == "--desktop" ]]; then
  cp "$DMG" "$HOME/Desktop/"
  echo "==> Copied to ~/Desktop/$(basename "$DMG")"
fi
