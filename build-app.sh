#!/bin/zsh
# Builds build/Meetboard.app (ad-hoc signed). --install copies it to /Applications and relaunches it.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Meetboard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O main.swift -o "$APP/Contents/MacOS/meetboard"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.otbic.meetboard</string>
  <key>CFBundleName</key><string>Meetboard</string>
  <key>CFBundleDisplayName</key><string>Meetboard</string>
  <key>CFBundleExecutable</key><string>meetboard</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Meetboard shows your next meeting and a countdown on a spare display.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x meetboard || true
  rm -rf /Applications/Meetboard.app
  cp -R "$APP" /Applications/
  open /Applications/Meetboard.app
  echo "Installed /Applications/Meetboard.app"
fi
