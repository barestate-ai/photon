#!/bin/bash
# Idempotent CEF vendoring. A dist counts as present only when its marker file holds the
# pinned sha1 of the tarball it was extracted from; then nothing is downloaded or touched.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION='156.0.14+g4fa4ab5+chromium-156.0.8078.48'
BASE='https://cef-builds.spotifycdn.com'
MINIMAL_SHA1='7359a9d293dd5c480bec3f18b762731b483b0e13'
CLIENT_SHA1='a80906135c78d90a564e022989084d741ab1cd9d'

mkdir -p Vendor
FRAMEWORK='Chromium Embedded Framework.framework/Chromium Embedded Framework'

fetch() {
  local kind=$1 sha1=$2
  local name="cef_binary_${VERSION}_macosarm64_${kind}"
  local marker="Vendor/.${kind}.sha1"
  if [ -d "Vendor/$name" ] && [ "$(cat "$marker" 2>/dev/null)" = "$sha1" ]; then
    echo "vendor: $kind up to date"
    return
  fi
  local stage="Vendor/.stage-$kind"
  rm -rf "$stage"
  mkdir -p "$stage"
  echo "vendor: downloading $kind"
  curl -fL --retry 3 --silent --show-error -o "$stage/$name.tar.bz2" "$BASE/${name//+/%2B}.tar.bz2"
  local actual
  actual=$(shasum -a 1 "$stage/$name.tar.bz2" | cut -d' ' -f1)
  if [ "$actual" != "$sha1" ]; then
    echo "vendor: $kind sha1 mismatch (got $actual, want $sha1)" >&2
    rm -rf "$stage"
    exit 1
  fi
  tar -xjf "$stage/$name.tar.bz2" -C "$stage"
  rm "$stage/$name.tar.bz2"
  # The client dist ships the same framework binary as the minimal one; share its blocks.
  local dup="$stage/$name/Release/cefclient.app/Contents/Frameworks/$FRAMEWORK"
  local orig="Vendor/cef_binary_${VERSION}_macosarm64_minimal/Release/$FRAMEWORK"
  if [ -f "$dup" ] && cmp -s "$dup" "$orig"; then
    cp -c -f "$orig" "$dup"
  fi
  rm -rf "Vendor/$name"
  mv "$stage/$name" "Vendor/$name"
  rmdir "$stage"
  echo "$sha1" > "$marker"
}

fetch minimal "$MINIMAL_SHA1"
fetch client "$CLIENT_SHA1"

minimal="cef_binary_${VERSION}_macosarm64_minimal"
client="cef_binary_${VERSION}_macosarm64_client"

link() {
  [ "$(readlink "Vendor/$1" 2>/dev/null)" = "$2" ] || ln -sfn "$2" "Vendor/$1"
}
link cef "$minimal"
link cefclient.app "$client/Release/cefclient.app"
