#!/bin/bash
# Assemble .build/Photon.app from the release build and ad-hoc sign it inside-out.
# Run `swift build -c release` first (make bundle does).
set -euo pipefail
cd "$(dirname "$0")/.."

# The product is Photon; the SwiftPM executable keeps its name, and CEF derives its helper names
# from the executable, so those stay "Barestate Helper ...".
APP_NAME="Photon"
EXEC_NAME="Barestate"
BUNDLE_ID="dev.barestate.browser"
BIN=.build/release
FRAMEWORK="Vendor/cef/Release/Chromium Embedded Framework.framework"
APP=".build/$APP_NAME.app"

[ -d "$FRAMEWORK" ] || { echo "bundle: run make vendor first" >&2; exit 1; }

rm -rf "$APP" ".build/$EXEC_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
# Remote starts it from beside the app's own executable.
cp "$BIN/barestate-gateway" "$APP/Contents/MacOS/barestate-gateway"
# The stdio MCP server for Muse Code (docs/muse-code.md); a release user has no .build.
cp "$BIN/barestate-mcp" "$APP/Contents/MacOS/barestate-mcp"

# Fonts are registered from here (never ~/Library/Fonts).
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"

# The phone page the gateway serves; -L turns its font symlink into the file.
cp -RL Resources/phone "$APP/Contents/Resources/phone"

# A DMG install runs Photon.app/Contents/Resources/atom/setup-atom.sh; the app launches atom_runtime.py from here.
cp -R runtime/atom "$APP/Contents/Resources/atom"
cp scripts/setup-atom.sh "$APP/Contents/Resources/atom/setup-atom.sh"

# APFS clone: instant and costs no extra disk.
cp -c -R "$FRAMEWORK" "$APP/Contents/Frameworks/"

plist() { # <path> <executable> <identifier> <name> <extra keys>
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$4</string>
  <key>CFBundleDisplayName</key><string>$4</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>LSEnvironment</key><dict><key>MallocNanoZone</key><string>0</string></dict>
  $5
</dict>
</plist>
EOF
}

plist "$APP/Contents/Info.plist" "$EXEC_NAME" "$BUNDLE_ID" "$APP_NAME" \
  '<key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>'
printf 'APPL????' > "$APP/Contents/PkgInfo"

# CEF fixes the helper naming: "<main executable> Helper<suffix>.app", executable named alike.
for suffix in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
  name="$EXEC_NAME Helper$suffix"
  tag=$(echo "$suffix" | tr -d ' ()' | tr 'A-Z' 'a-z')
  contents="$APP/Contents/Frameworks/$name.app/Contents"
  mkdir -p "$contents/MacOS"
  cp "$BIN/BarestateHelper" "$contents/MacOS/$name"
  printf 'APPL????' > "$contents/PkgInfo"
  plist "$contents/Info.plist" "$name" "$BUNDLE_ID.helper${tag:+.$tag}" "$name" \
    '<key>LSUIElement</key><string>1</string>
  <key>LSFileQuarantineEnabled</key><true/>'
done

# Innermost first. No --deep: it would hide an ordering mistake.
SIGN=(codesign --force --sign - --timestamp=none)
fw="$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
for lib in "$fw"/Libraries/*.dylib; do "${SIGN[@]}" "$lib"; done
"${SIGN[@]}" "$fw/Chromium Embedded Framework"
for helper in "$APP/Contents/Frameworks/"*Helper*.app; do "${SIGN[@]}" "$helper"; done
"${SIGN[@]}" "$APP/Contents/MacOS/barestate-gateway"
"${SIGN[@]}" "$APP/Contents/MacOS/barestate-mcp"
"${SIGN[@]}" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "bundled: $APP"
