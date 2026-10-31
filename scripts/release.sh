#!/bin/bash
# Build the release bundle and zip it as dist/Photon-<version>.zip. Replaces only an older Photon zip:
# dist/ may also hold the DMG (scripts/dmg.sh), the model archive and SHA256SUMS, which stay.
# Never builds a second copy of the app: the disk cannot hold one.
set -euo pipefail
cd "$(dirname "$0")/.."

make --no-print-directory bundle
APP=".build/Photon.app"

# Ad-hoc signing, no Kyoto art, the two OFL fonts: assert it before shipping.
for font in Manrope-Variable.ttf InstrumentSerif-Regular.ttf; do
  [ -f "$APP/Contents/Resources/Fonts/$font" ] || { echo "release: $font is not bundled" >&2; exit 1; }
done
[ -z "$(find "$APP" -iname '*kyoto*' -o -name Art)" ] || { echo "release: Kyoto art is in the bundle" >&2; exit 1; }

# The zip is at most the size of the app; keep 1.5 GB free after it.
free_kb=$(df -k . | awk 'NR==2 {print $4}')
app_kb=$(du -sk "$APP" | cut -f1)
if [ $((free_kb - app_kb)) -lt 1500000 ]; then
  echo "release: ${free_kb} KB free; a ${app_kb} KB zip would leave under 1.5 GB" >&2
  exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
mkdir -p dist
rm -f dist/Photon-*.zip
# ditto keeps the signatures, symlinks and extended attributes that zip(1) drops.
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/Photon-$version.zip"
echo "released: dist/Photon-$version.zip"
