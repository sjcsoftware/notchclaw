#!/usr/bin/env bash
# Regenerates README screenshots (docs/images) and the icon preview from a debug build.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${SDKROOT:-}" ]]; then
  for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk; do [[ -d "$sdk" ]] && export SDKROOT="$sdk"; done
fi
swift build
mkdir -p docs/images
NOTCHCLAW_SNAPSHOT_DIR="$PWD/docs/images" .build/debug/NotchClaw
TMP="$(mktemp -d)"
swift scripts/make-icon.swift "$TMP/AppIcon.iconset" "$TMP/icon.png" >/dev/null
sips -z 256 256 "$TMP/icon.png" --out docs/images/icon.png >/dev/null
rm -rf "$TMP"
ls docs/images
