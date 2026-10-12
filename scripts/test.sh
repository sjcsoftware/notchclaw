#!/usr/bin/env bash
# Runs the Swift Testing suite with only the Command Line Tools installed.
set -euo pipefail
cd "$(dirname "$0")/.."

CLT=/Library/Developer/CommandLineTools
if [[ -z "${SDKROOT:-}" ]]; then
  for sdk in $CLT/SDKs/MacOSX26*.sdk; do [[ -d "$sdk" ]] && export SDKROOT="$sdk"; done
fi
FRAMEWORKS=$CLT/Library/Developer/Frameworks

swift test \
  -Xswiftc -plugin-path -Xswiftc $CLT/usr/lib/swift/host/plugins/testing \
  -Xswiftc -F -Xswiftc $FRAMEWORKS \
  -Xlinker -rpath -Xlinker $FRAMEWORKS "$@"
