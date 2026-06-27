#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="Codex Account Switcher"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BIN_PATH="$MACOS_DIR/CodexAccountSwitcher"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"

cleanup_codex_code_sign_clones() {
  local temp_parent="${TMPDIR:-/tmp}"
  temp_parent="$(cd "$temp_parent/.." 2>/dev/null && pwd -P || true)"
  local clone_dir="$temp_parent/X/com.openai.codex.code_sign_clone"
  case "$clone_dir" in
    /private/var/folders/*/X/com.openai.codex.code_sign_clone|/var/folders/*/X/com.openai.codex.code_sign_clone)
      rm -rf "$clone_dir"
      ;;
  esac
}

cleanup_codex_code_sign_clones
trap cleanup_codex_code_sign_clones EXIT

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE_DIR"

if [[ -f "/Applications/Codex.app/Contents/Resources/icon.icns" ]]; then
  cp "/Applications/Codex.app/Contents/Resources/icon.icns" "$RESOURCES_DIR/CodexIcon.icns"
fi

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" swiftc "$ROOT_DIR/Sources/main.swift" \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework AppKit \
  -framework UserNotifications \
  -o "$BIN_PATH"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>CodexAccountSwitcher</string>
  <key>CFBundleIdentifier</key>
  <string>local.codex-account-switcher.menu-bar</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Codex Account Switcher</string>
  <key>CFBundleIconFile</key>
  <string>CodexIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(
    security find-identity -p codesigning -v 2>/dev/null \
      | sed -n 's/^[[:space:]]*[0-9][0-9]*) [A-F0-9]* "\(Apple Development:[^"]*\)".*/\1/p' \
      | head -n 1
  )"
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign --remove-signature "$BIN_PATH" 2>/dev/null || true
  codesign --force --sign "$SIGNING_IDENTITY" \
    --identifier "local.codex-account-switcher.menu-bar" \
    --requirements '=designated => identifier "local.codex-account-switcher.menu-bar" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: flashxjapan@gmail.com (R38YYZHMHK)" and certificate 1[field.1.2.840.113635.100.6.2.1] exists' \
    "$APP_DIR"
else
  codesign --remove-signature "$BIN_PATH" 2>/dev/null || true
  codesign --force --sign - \
    --identifier "local.codex-account-switcher.menu-bar" \
    "$APP_DIR"
fi

echo "$APP_DIR"
