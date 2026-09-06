#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Building Flipgrade…"
swift build -c debug
BUILD_STATUS=$?
if [[ $BUILD_STATUS -ne 0 ]]; then
  echo "Build failed ($BUILD_STATUS)"
  exit $BUILD_STATUS
fi

APP="$ROOT/Flipgrade.app"
BIN="$ROOT/.build/debug/Flipgrade"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Flipgrade</string>
  <key>CFBundleIdentifier</key>
  <string>com.flipgrade.app</string>
  <key>CFBundleName</key>
  <string>Flipgrade</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

cp "$BIN" "$APP/Contents/MacOS/Flipgrade"
chmod +x "$APP/Contents/MacOS/Flipgrade"
printf '%s\n' "$ROOT" > "$APP/Contents/Resources/repo-root.txt"

# Drop any previous instance so we don't stack invisible processes.
pkill -x Flipgrade 2>/dev/null || true
sleep 0.2

echo "Opening $APP"
open "$APP"
echo "If you still see no window: check Dock for Flipgrade, or run: open \"$APP\""
