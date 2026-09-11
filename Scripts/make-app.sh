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
    <key>LSMinimumSystemVersion</key>      <string>13.0</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <!-- No Dock icon and no app menu: menu bar item only. -->
    <key>LSUIElement</key>                 <true/>
</dict>
</plist>
PLIST

# App Sandbox is deliberately NOT enabled: there is no entitlements file, so the
# bundle runs outside the sandbox. The reason is explained in the README (IOKit HID access).
echo "==> Ad-hoc signing"
codesign --force --sign - "$APP"

echo
echo "Ready: $APP"
echo "Run:   open \"$APP\""
echo "Stop:  menu bar icon > Quit   (or: pkill -x MacBookUno)"
