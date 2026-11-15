#!/bin/bash
# Builds build/Singer.app (release).
#   scripts/build-app.sh                 ad-hoc signed, for local use
#   scripts/build-app.sh --notarize      Developer ID signed, notarized and stapled
#   add --install to copy the result to /Applications
#
# Env: SIGN_IDENTITY (default: first "Developer ID Application" identity)
#      NOTARY_PROFILE (notarytool keychain profile, see `xcrun notarytool store-credentials`)
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARIZE=0; INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --notarize) NOTARIZE=1 ;;
        --install) INSTALL=1 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

swift build -c release
APP=build/Singer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Singer" "$APP/Contents/MacOS/Singer"
cp Resources/Info.plist "$APP/Contents/Info.plist"

ICONSET=build/AppIcon.iconset
if [ ! -f build/AppIcon.icns ]; then
    swift scripts/make-icon.swift "$ICONSET"
    iconutil -c icns "$ICONSET" -o build/AppIcon.icns
    rm -rf "$ICONSET"
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ "$NOTARIZE" = 1 ]; then
    IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
    [ -n "$IDENTITY" ] || { echo "No Developer ID Application identity found" >&2; exit 1; }
    : "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile}"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    ZIP=build/Singer.zip
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"   # stapled copy for distribution
else
    codesign --force --sign - "$APP"
fi
echo "Built $APP"

if [ "$INSTALL" = 1 ]; then
    pkill -x Singer 2>/dev/null || true
    rm -rf /Applications/Singer.app
    ditto "$APP" /Applications/Singer.app
    echo "Installed to /Applications/Singer.app"
fi
