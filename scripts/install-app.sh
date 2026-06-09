#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Ephemeral Notes"
SOURCE_APP="$ROOT/dist/$APP_NAME.app"
if [[ -w "/Applications" ]]; then
  TARGET_DIR="/Applications"
else
  TARGET_DIR="$HOME/Applications"
fi
TARGET_APP="$TARGET_DIR/$APP_NAME.app"

"$ROOT/scripts/build-app.sh"

mkdir -p "$TARGET_DIR"
rm -rf "$TARGET_APP"
cp -R "$SOURCE_APP" "$TARGET_APP"
rm -rf "$SOURCE_APP"

echo "$TARGET_APP"
