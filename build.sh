#!/bin/bash
# Builds build/Pauline.app from source with SwiftPM. No Xcode project needed.
set -euo pipefail
cd "$(dirname "$0")"

# /usr/bin/swift exists even without developer tools, xcrun tells whether a real one is installed.
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Swift is missing. Install the Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi
major="$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | head -n 1)"
if [ "${major:-0}" -lt 6 ]; then
  echo "Pauline needs Swift 6 or later. Found: $(swift --version 2>&1 | head -n 1)" >&2
  echo "Swift 6 comes with Xcode 16 or its Command Line Tools, on macOS 14.5 or later." >&2
  exit 1
fi

swift build -c release --product Pauline
bin="$(swift build -c release --show-bin-path)/Pauline"

app="build/Pauline.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/Pauline"
cp Support/Info.plist "$app/Contents/Info.plist"
# Ad hoc signature: enough to run on the Mac that built it.
codesign --force --sign - "$app"

echo "Built $app"
