#!/bin/bash
# Builds the iPhone app (Release) and installs it on a connected iPhone.
#   scripts/install-iphone.sh [device-id]     default: first connected iPhone
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
DD=build/ios-release
xcodebuild -project SingerPhone.xcodeproj -scheme SingerPhone -configuration Release \
  -destination "generic/platform=iOS" -derivedDataPath "$DD" -allowProvisioningUpdates build -quiet
DEVICES=$(xcrun devicectl list devices 2>/dev/null || true)
ID="${1:-$(grep -E 'iPhone.*[[:space:]](available|connected)[[:space:]]' <<< "$DEVICES" | grep physical | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)}"
[ -n "$ID" ] || { echo "No connected iPhone found" >&2; exit 1; }
xcrun devicectl device install app --device "$ID" "$DD/Build/Products/Release-iphoneos/Singer.app"
echo "Installed Singer on $ID"
