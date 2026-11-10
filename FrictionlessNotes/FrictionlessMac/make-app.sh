#!/bin/zsh
# Build the package and wrap the executable in a minimal .app bundle so it runs
# as a real Mac app (menu bar extra, Dock, notifications later). Output:
#   FrictionlessMac/build/FrictionlessMac.app
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
swift build -c debug
BIN=$(swift build -c debug --show-bin-path)
APP=build/FrictionlessMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FrictionlessMac" "$APP/Contents/MacOS/FrictionlessMac"
cp -R "$BIN/FrictionlessMac_FrictionlessMac.bundle" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Program</string>
  <key>CFBundleDisplayName</key><string>Program</string>
  <key>CFBundleIdentifier</key><string>JAF.FrictionlessMac</string>
  <key>CFBundleExecutable</key><string>FrictionlessMac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP"
