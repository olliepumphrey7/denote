#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Denote"
BUNDLE="$ROOT/dist/$APP_NAME.app"
CONTENTS="$BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"

cd "$ROOT"
swift build -c release

rm -rf "$BUNDLE"
mkdir -p "$MACOS" "$CONTENTS/Resources"
cp ".build/release/Denote" "$MACOS/Denote"
if [[ -d ".build/arm64-apple-macosx/release/Denote_Denote.bundle" ]]; then
  cp -R ".build/arm64-apple-macosx/release/Denote_Denote.bundle" "$CONTENTS/Resources/"
elif [[ -d ".build/release/Denote_Denote.bundle" ]]; then
  cp -R ".build/release/Denote_Denote.bundle" "$CONTENTS/Resources/"
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Denote</string>
  <key>CFBundleIdentifier</key>
  <string>local.denote</string>
  <key>CFBundleName</key>
  <string>Denote</string>
  <key>CFBundleDisplayName</key>
  <string>Denote</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "$BUNDLE"
