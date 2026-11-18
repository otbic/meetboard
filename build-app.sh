#!/bin/zsh
# Builds build/Meetboard.app. Ad-hoc signed unless MEETBOARD_SIGN names a signing identity (e.g. "Apple Development");
# a real identity keeps calendar and location permission across rebuilds. --install copies it to /Applications and relaunches it.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Meetboard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O main.swift Board.swift Sources.swift Settings.swift -o "$APP/Contents/MacOS/meetboard"
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
  <key>CFBundleShortVersionString</key><string>0.4.0</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocationUsageDescription</key><string>Meetboard shows the local weather next to the clock. Your location is rounded to about 1 km.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Meetboard shows the local weather next to the clock. Your location is rounded to about 1 km.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Meetboard shows your next meeting and a countdown on a spare display.</string>
</dict></plist>
PLIST
codesign --force --sign "${MEETBOARD_SIGN:--}" "$APP"
echo "Built: $PWD/$APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x meetboard || true
  rm -rf /Applications/Meetboard.app
  cp -R "$APP" /Applications/
  open /Applications/Meetboard.app
  echo "Installed /Applications/Meetboard.app"
fi
