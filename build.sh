#!/bin/bash
# Builds Droplet.app next to this script.
#   ./build.sh           build only
#   ./build.sh run       build and launch from here
#   ./build.sh install   build, copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="Droplet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$(swift build -c release --show-bin-path)/Droplet" "$APP/Contents/MacOS/Droplet"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Droplet</string>
    <key>CFBundleDisplayName</key><string>Droplet</string>
    <key>CFBundleIdentifier</key><string>local.droplet.island</string>
    <key>CFBundleExecutable</key><string>Droplet</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Droplet reads the current track and controls playback in Music and Spotify.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

case "${1:-}" in
run)
    pkill -x Droplet 2>/dev/null || true
    sleep 0.5
    open "$APP"
    ;;
install)
    pkill -x Droplet 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/Droplet.app
    cp -R "$APP" /Applications/Droplet.app
    open /Applications/Droplet.app
    echo "Installed to /Applications/Droplet.app"
    ;;
esac
