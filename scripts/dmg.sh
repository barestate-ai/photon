#!/bin/bash
# Pack .build/Photon.app (make bundle) into dist/Photon-<version>.dmg: the app and an Applications
# symlink to drag it onto. Never builds: the disk cannot hold a second copy of the app.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=".build/Photon.app"
[ -d "$APP" ] || { echo "dmg: $APP is missing; run make bundle first" >&2; exit 1; }

# The image is at most the size of the app (UDZO only shrinks it); keep 1.5 GB free after it.
free_kb=$(df -k . | awk 'NR==2 {print $4}')
app_kb=$(du -sk "$APP" | cut -f1)
if [ $((free_kb - app_kb)) -lt 1500000 ]; then
  echo "dmg: ${free_kb} KB free; a ${app_kb} KB image would leave under 1.5 GB" >&2
  exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
stage=".build/dmg-stage"
trap 'rm -rf "$stage"' EXIT
rm -rf "$stage"
mkdir -p "$stage" dist
# APFS clone beside the bundle: instant, no extra disk, signature and xattrs intact.
cp -cR "$APP" "$stage/Photon.app"
ln -s /Applications "$stage/Applications"

hdiutil create -volname Photon -fs HFS+ -format UDZO -ov -srcfolder "$stage" "dist/Photon-$version.dmg"
echo "dmg: dist/Photon-$version.dmg"
