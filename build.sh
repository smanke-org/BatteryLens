#!/bin/bash
# Development build: builds Release (Developer ID signed) for this Mac's architecture,
# installs it as /Applications/BatteryLens.app and relaunches it. Installing in one place
# keeps a single copy of the widget in the widget gallery and keeps permissions stable.
# The build is notarized too: the widget service ignores widgets from an unnotarized
# Developer ID app ("restricted or unknown extension"). NOTARIZE=0 skips it.
# release.sh runs it with UNIVERSAL=1 (both architectures) and INSTALL=0.
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate >/dev/null
PRODUCTS=.build/xcode/Build/Products/Release
rm -rf "$PRODUCTS/BatteryLens.app"
xcodebuild -project BatteryLens.xcodeproj -scheme BatteryLens -configuration Release \
  -derivedDataPath .build/xcode ONLY_ACTIVE_ARCH=$([ "${UNIVERSAL:-0}" = 1 ] && echo NO || echo YES) build | grep -E "error:|warning: .*/BatteryLens/|BUILD" || true
APP="$PRODUCTS/BatteryLens.app"
[ -d "$APP/Contents/PlugIns/BatteryLensWidget.appex" ] || { echo "Build failed or the widget is missing." >&2; exit 1; }

if [ "${NOTARIZE:-1}" != 0 ]; then
  ZIP=.build/BatteryLens-notary.zip
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile DesktopBins --wait | grep -E "status:" | tail -1
  xcrun stapler staple "$APP" >/dev/null
fi
[ "${INSTALL:-1}" = 0 ] && exit 0

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
pkill -x BatteryLens || true
# The widget's process outlives an update and keeps running the old code; the widget
# service starts the new one on the next reload.
pkill -f "BatteryLens.app/Contents/PlugIns/BatteryLensWidget.appex" || true
# In place rather than delete-and-copy: replacing the bundle orphans its permissions.
mkdir -p /Applications/BatteryLens.app
rsync -a --delete "$APP/" /Applications/BatteryLens.app/
# Only the installed copy should offer the widget.
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
"$LSREGISTER" -f /Applications/BatteryLens.app
codesign --verify --deep --strict /Applications/BatteryLens.app
open /Applications/BatteryLens.app
echo "Installed BatteryLens $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/BatteryLens.app/Contents/Info.plist) ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/BatteryLens.app/Contents/Info.plist))"
