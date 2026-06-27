#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$(/bin/bash "$ROOT_DIR/build.sh")"
DEST_DIR="$HOME/Applications"
DEST_APP="$DEST_DIR/Codex Account Switcher.app"

mkdir -p "$DEST_DIR"
pkill -f "$DEST_APP/Contents/MacOS/CodexAccountSwitcher" 2>/dev/null || true
for _ in {1..20}; do
  if ! pgrep -f "$DEST_APP/Contents/MacOS/CodexAccountSwitcher" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
rm -rf "$DEST_APP"
cp -R "$APP_PATH" "$DEST_APP"

echo "$DEST_APP"
