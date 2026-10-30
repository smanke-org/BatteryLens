#!/bin/bash
# Builds the distributable .dmg from the notarized app build.sh made, with the usual
# drag-to-Applications layout, then signs, notarizes and staples the image itself so the
# download is clean too.
set -euo pipefail
cd "$(dirname "$0")"

APP=".build/xcode/Build/Products/Release/BatteryLens.app"
OUT=".build/dist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP}/Contents/Info.plist")
DMG_PATH="${OUT}/BatteryLens-${VERSION}.dmg"
STABLE_PATH="${OUT}/BatteryLens.dmg"
PROFILE="${NOTARY_PROFILE:-DesktopBins}"

[ -d "${APP}" ] || { echo "No app at ${APP}; run UNIVERSAL=1 INSTALL=0 ./build.sh first." >&2; exit 1; }
xcrun stapler validate "${APP}" >/dev/null 2>&1 || { echo "The app has no stapled notarization ticket." >&2; exit 1; }

SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -n 1 | sed -E 's/.*"(.*)".*/\1/')
[ -n "${SIGN_IDENTITY}" ] || { echo "No Developer ID identity found." >&2; exit 1; }

mkdir -p "${OUT}"
STAGING=$(mktemp -d)
trap 'rm -rf "${STAGING}"' EXIT
ditto "${APP}" "${STAGING}/BatteryLens.app"
ln -s /Applications "${STAGING}/Applications"
# The window layout (600x400, 128px icons, app left, Applications right) ships as a
# captured .DS_Store; recapture with Tools/capture_dmg_layout.sh. Driving Finder at release
# time is too unreliable to sit in a release path.
[ -f "Resources/dmg/DS_Store" ] && cp "Resources/dmg/DS_Store" "${STAGING}/.DS_Store"

echo "Creating ${DMG_PATH}..."
rm -f "${DMG_PATH}"
# LZFSE (ULFO), not zlib (UDZO): on macOS 27 hdiutil can write a corrupt zlib image of an
# HFS+ volume, which notarytool then refuses.
hdiutil create -volname "BatteryLens" -srcfolder "${STAGING}" -fs HFS+ -format ULFO -ov "${DMG_PATH}" >/dev/null
hdiutil imageinfo "${DMG_PATH}" 2>/dev/null | grep -q "Format Description" \
  || { echo "The disk image came out unreadable; not signing or publishing it." >&2; exit 1; }

codesign --force --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
echo "Notarizing the disk image..."
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${PROFILE}" --wait | grep -E "status:" | tail -1
xcrun stapler staple "${DMG_PATH}" >/dev/null
xcrun stapler validate "${DMG_PATH}" >/dev/null || { echo "The disk image isn't stapled." >&2; exit 1; }

# The README links to releases/latest/download/BatteryLens.dmg, which only resolves
# against an asset with the same name in every release.
cp "${DMG_PATH}" "${STABLE_PATH}"
spctl -a -t open --context context:primary-signature -vv "${DMG_PATH}" 2>&1 | head -2
echo "Done: ${DMG_PATH} and ${STABLE_PATH}"
