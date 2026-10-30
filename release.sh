#!/bin/bash
# Cuts a release: universal notarized build, disk image, tag, GitHub release.
#
# Usage: ./release.sh [version]
#   With no argument, releases the MARKETING_VERSION project.yml already carries.
#   RELEASE_NOTES="..." sets the release notes.
set -euo pipefail
cd "$(dirname "$0")"

# Before touching anything, so the script's own version edit can't trip it.
if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit before releasing so the tag matches what shipped." >&2
  exit 1
fi

CURRENT=$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]*)"?$/\1/p' project.yml | head -1)
VERSION="${1:-${CURRENT}}"
if [ "${VERSION}" != "${CURRENT}" ]; then
  echo "==> Setting version to ${VERSION}"
  sed -i '' -E "s/^( *MARKETING_VERSION: *).*/\1\"${VERSION}\"/" project.yml
  # Commit it, so the tag points at a commit carrying the version that shipped.
  git add project.yml
  git commit -q -m "Bump to ${VERSION}"
  git push -q origin HEAD
fi
TAG="v${VERSION}"
# The beta label goes in the titles only: a GitHub pre-release is skipped by the
# releases/latest lookups the updater and the README's download link rely on.
STAGE=$(/usr/libexec/PlistBuddy -c "Print :BatteryLensReleaseStage" Resources/Info.plist 2>/dev/null || true)

if gh release view "${TAG}" >/dev/null 2>&1; then
  echo "Release ${TAG} already exists. Bump the version first." >&2
  exit 1
fi

UNIVERSAL=1 INSTALL=0 ./build.sh
APP=.build/xcode/Build/Products/Release/BatteryLens.app
BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP}/Contents/Info.plist")
[ "${BUILT}" = "${VERSION}" ] || { echo "Built ${BUILT}, expected ${VERSION}." >&2; exit 1; }
lipo -archs "${APP}/Contents/MacOS/BatteryLens" | grep -q "x86_64" || { echo "The build isn't universal." >&2; exit 1; }
./make_dmg.sh

echo "==> Tagging ${TAG}"
git tag -a "${TAG}" -m "BatteryLens ${VERSION}${STAGE:+ ${STAGE}}"
git push origin "${TAG}"

echo "==> Publishing ${TAG}"
gh release create "${TAG}" ".build/dist/BatteryLens-${VERSION}.dmg" ".build/dist/BatteryLens.dmg" \
  --title "BatteryLens ${VERSION}${STAGE:+ ${STAGE}}" \
  --notes "${RELEASE_NOTES:-See the commit history for what changed in ${VERSION}.}"

echo "==> Verifying the permanent download link"
URL="https://github.com/smanke-org/BatteryLens/releases/latest/download/BatteryLens.dmg"
for attempt in 1 2 3 4 5 6; do
  CODE=$(curl -sL -o /dev/null -w "%{http_code}" "${URL}")
  if [ "${CODE}" = "200" ]; then
    echo "    ${URL} -> 200"
    echo "Released ${TAG}."
    exit 0
  fi
  echo "    attempt ${attempt}: ${CODE}, waiting..."
  sleep 10
done
echo "The permanent download link is still not resolving (${CODE}). Check the release assets." >&2
exit 1
