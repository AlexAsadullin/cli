#!/bin/zsh
# Builds "Claude Scheduler.app" and installs it into ~/Applications.
set -euo pipefail
cd "${0:A:h}"

BUILD=build
APP="$BUILD/Claude Scheduler.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/icon.iconset"

# Icon
swiftc -O Sources/IconGen/main.swift -o "$BUILD/icongen"
"$BUILD/icongen" Resources/icon-src/clock.svg "$BUILD/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon-1024.png" --out "$BUILD/icon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BUILD/icon-1024.png" --out "$BUILD/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/icon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# App
swiftc -O -parse-as-library -target arm64-apple-macos14 \
  Sources/Store.swift Sources/App.swift \
  -o "$APP/Contents/MacOS/ClaudeScheduler"
cp Resources/run-task.sh Resources/icon-src/clock.svg "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP" >/dev/null

mkdir -p ~/Applications
rm -rf ~/Applications/"Claude Scheduler.app"
cp -R "$APP" ~/Applications/
echo "Installed: ~/Applications/Claude Scheduler.app"
