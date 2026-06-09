#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Ephemeral Notes"
BUNDLE="$ROOT/dist/$APP_NAME.app"
CONTENTS="$BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"

cd "$ROOT"
swift build -c release

rm -rf "$BUNDLE"
mkdir -p "$MACOS" "$CONTENTS/Resources"
cp ".build/release/EphemeralNotes" "$MACOS/EphemeralNotes"
if [[ -d ".build/arm64-apple-macosx/release/EphemeralNotes_EphemeralNotes.bundle" ]]; then
  cp -R ".build/arm64-apple-macosx/release/EphemeralNotes_EphemeralNotes.bundle" "$CONTENTS/Resources/"
elif [[ -d ".build/release/EphemeralNotes_EphemeralNotes.bundle" ]]; then
  cp -R ".build/release/EphemeralNotes_EphemeralNotes.bundle" "$CONTENTS/Resources/"
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>EphemeralNotes</string>
  <key>CFBundleIdentifier</key>
  <string>local.ephemeral-notes</string>
  <key>CFBundleName</key>
  <string>Ephemeral Notes</string>
  <key>CFBundleDisplayName</key>
  <string>Ephemeral Notes</string>
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
