#!/bin/bash
# Builds the MacBookUno.app bundle.
#
# Why this is needed: `swift run MacBookUno` is enough to run the menu bar app
# (the activation policy is set in code), but adding it to Login Items or
# opening it from Finder requires a real .app bundle.
#
# Usage:  ./Scripts/make-app.sh  [output-directory]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT/build}"
APP="$OUT_DIR/MacBookUno.app"

# Read the version from the single source of truth so the bundle can never
# disagree with the binary.
VERSION="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' "$ROOT/Sources/LidAngleKit/Version.swift")"
if [ -z "$VERSION" ]; then
    echo "error: could not read the version from Sources/LidAngleKit/Version.swift" >&2
    exit 1
fi
echo "==> Version $VERSION"

echo "==> Building release"
swift build -c release --package-path "$ROOT"
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/MacBookUno"

echo "==> Creating bundle: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacBookUno"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>MacBookUno</string>
    <key>CFBundleIdentifier</key>          <string>com.orknkrc.macbookuno</string>
    <key>CFBundleName</key>                <string>MacBookUno</string>
    <key>CFBundleDisplayName</key>         <string>MacBookUno</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundleVersion</key>             <string>$VERSION</string>
    <!-- Must track Package.swift. The Fold Plane style uses SCScreenshotManager,
         which is macOS 14; declaring 13 here lets the app install on a system
         where it cannot run. -->
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <!-- No Dock icon and no app menu: menu bar item only. -->
    <key>LSUIElement</key>                 <true/>
</dict>
</plist>
PLIST

# App Sandbox is deliberately NOT enabled: there is no entitlements file, so the
# bundle runs outside the sandbox. The reason is explained in the README (IOKit HID access).
# Sign with a real identity when one exists, ad-hoc otherwise.
#
# This matters for more than tidiness. The Fold Plane style needs Screen
# Recording permission, and macOS remembers that grant against the app's code
# signature. An ad-hoc signature is just a hash of the binary, so every rebuild
# looks like a different app and the permission has to be granted again. A
# self-signed certificate keeps the identity stable across rebuilds.
#
# To create one: Keychain Access > Certificate Assistant > Create a Certificate,
# type "Code Signing", self-signed. Then either export CODESIGN_IDENTITY or let
# this script pick it up automatically.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(.*\)"$/\1/p' | head -1)"
fi

if [ -n "$IDENTITY" ]; then
    echo "==> Signing as: $IDENTITY"
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
    echo "==> Ad-hoc signing (no code signing identity found)"
    echo "    Screen Recording permission will be asked for again after every"
    echo "    rebuild. See the comment above this line in Scripts/make-app.sh."
    codesign --force --sign - "$APP"
fi

echo
echo "Ready: $APP"
echo "Run:   open \"$APP\""
echo "Stop:  menu bar icon > Quit   (or: pkill -x MacBookUno)"
