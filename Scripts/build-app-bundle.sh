#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
VERSION_FILE="${VERSION_FILE:-$ROOT_DIR/VERSION}"
APP_VERSION="${APP_VERSION:-}"
APP_BUILD_VERSION="${APP_BUILD_VERSION:-}"
APP_NAME="Shitsurae"
BUNDLE_NAME="${BUNDLE_NAME:-Shitsurae}"
AGENT_NAME="ShitsuraeAgent"
CLI_NAME="shitsurae-cli"
BUNDLED_CLI_NAME="shitsurae"
CORE_BUNDLE_NAME="shitsurae_ShitsuraeCore.bundle"
ICON_NAME="${ICON_NAME:-Shitsurae}"
ICON_SOURCE_DIR="$ROOT_DIR/Shitsurae/Assets.xcassets/AppIcon.appiconset"
MENU_ICON_SOURCE_DIR="$ROOT_DIR/Shitsurae/Assets.xcassets/MenuBarIcon.imageset"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE_PATH="$DIST_DIR/${BUNDLE_NAME}.app"
APP_CONTENTS_PATH="$APP_BUNDLE_PATH/Contents"
APP_MACOS_PATH="$APP_CONTENTS_PATH/MacOS"
APP_RESOURCES_PATH="$APP_CONTENTS_PATH/Resources"
APP_PLIST_PATH="$APP_CONTENTS_PATH/Info.plist"
APP_BUNDLE_ID=""
AGENT_BUNDLE_ID="com.yuki-yano.shitsurae.agent"
CLI_BUNDLE_ID="com.yuki-yano.shitsurae.cli"

resolve_default_version() {
  if [[ ! -f "$VERSION_FILE" ]]; then
    echo "error: missing version file: $VERSION_FILE" >&2
    exit 1
  fi

  local resolved
  resolved="$(tr -d '[:space:]' < "$VERSION_FILE")"

  if [[ -z "$resolved" ]]; then
    echo "error: empty version in $VERSION_FILE" >&2
    exit 1
  fi

  printf '%s' "$resolved"
}

validate_version() {
  local label="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "error: $label must contain only digits and dots: $value" >&2
    exit 1
  fi
}

if [[ -z "$APP_VERSION" ]]; then
  APP_VERSION="$(resolve_default_version)"
fi

if [[ -z "$APP_BUILD_VERSION" ]]; then
  APP_BUILD_VERSION="$APP_VERSION"
fi

validate_version "APP_VERSION" "$APP_VERSION"
validate_version "APP_BUILD_VERSION" "$APP_BUILD_VERSION"

cd "$ROOT_DIR"

./Scripts/generate-icons.sh

swift build -c "$CONFIGURATION"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

if [[ ! -x "$BIN_DIR/$APP_NAME" ]]; then
  echo "error: missing app binary: $BIN_DIR/$APP_NAME" >&2
  exit 1
fi

if [[ ! -x "$BIN_DIR/$AGENT_NAME" ]]; then
  echo "error: missing agent binary: $BIN_DIR/$AGENT_NAME" >&2
  exit 1
fi

if [[ ! -x "$BIN_DIR/$CLI_NAME" ]]; then
  echo "error: missing CLI binary: $BIN_DIR/$CLI_NAME" >&2
  exit 1
fi

if [[ ! -f "$ROOT_DIR/Shitsurae/Info.plist" ]]; then
  echo "error: missing app Info.plist: $ROOT_DIR/Shitsurae/Info.plist" >&2
  exit 1
fi

if [[ ! -d "$BIN_DIR/$CORE_BUNDLE_NAME" ]]; then
  echo "error: missing core resource bundle: $BIN_DIR/$CORE_BUNDLE_NAME" >&2
  exit 1
fi

if [[ ! -d "$ICON_SOURCE_DIR" ]]; then
  echo "error: missing app icon source directory: $ICON_SOURCE_DIR" >&2
  exit 1
fi

if [[ ! -d "$MENU_ICON_SOURCE_DIR" ]]; then
  echo "error: missing menu bar icon source directory: $MENU_ICON_SOURCE_DIR" >&2
  exit 1
fi

if ! command -v iconutil >/dev/null 2>&1; then
  echo "error: iconutil command not found" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ICONSET_DIR="$TMP_DIR/${ICON_NAME}.iconset"
mkdir -p "$ICONSET_DIR"

ICON_MAP=(
  "icon_16.png:icon_16x16.png"
  "icon_16@2x.png:icon_16x16@2x.png"
  "icon_32.png:icon_32x32.png"
  "icon_32@2x.png:icon_32x32@2x.png"
  "icon_128.png:icon_128x128.png"
  "icon_128@2x.png:icon_128x128@2x.png"
  "icon_256.png:icon_256x256.png"
  "icon_256@2x.png:icon_256x256@2x.png"
  "icon_512.png:icon_512x512.png"
  "icon_512@2x.png:icon_512x512@2x.png"
)

for entry in "${ICON_MAP[@]}"; do
  source_name="${entry%%:*}"
  target_name="${entry##*:}"
  if [[ ! -f "$ICON_SOURCE_DIR/$source_name" ]]; then
    echo "error: missing icon source file: $ICON_SOURCE_DIR/$source_name" >&2
    exit 1
  fi
  cp "$ICON_SOURCE_DIR/$source_name" "$ICONSET_DIR/$target_name"
done

rm -rf "$APP_BUNDLE_PATH"
mkdir -p "$APP_MACOS_PATH" "$APP_RESOURCES_PATH"

cp "$BIN_DIR/$APP_NAME" "$APP_MACOS_PATH/$APP_NAME"
cp "$BIN_DIR/$CLI_NAME" "$APP_RESOURCES_PATH/$BUNDLED_CLI_NAME"
cp "$ROOT_DIR/Shitsurae/Info.plist" "$APP_PLIST_PATH"
cp "$BIN_DIR/$AGENT_NAME" "$APP_RESOURCES_PATH/$AGENT_NAME"
cp -R "$BIN_DIR/$CORE_BUNDLE_NAME" "$APP_RESOURCES_PATH/$CORE_BUNDLE_NAME"
cp "$MENU_ICON_SOURCE_DIR/menu-16.png" "$APP_RESOURCES_PATH/menu-16.png"
cp "$MENU_ICON_SOURCE_DIR/menu-32.png" "$APP_RESOURCES_PATH/menu-32.png"
iconutil -c icns "$ICONSET_DIR" -o "$APP_RESOURCES_PATH/${ICON_NAME}.icns"

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_PLIST_PATH" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$APP_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$APP_PLIST_PATH" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $BUNDLE_NAME" "$APP_PLIST_PATH" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string $BUNDLE_NAME" "$APP_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $BUNDLE_NAME" "$APP_PLIST_PATH" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $BUNDLE_NAME" "$APP_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_PLIST_PATH" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$APP_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD_VERSION" "$APP_PLIST_PATH" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $APP_BUILD_VERSION" "$APP_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $ICON_NAME" "$APP_PLIST_PATH" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $ICON_NAME" "$APP_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconName $ICON_NAME" "$APP_PLIST_PATH" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string $ICON_NAME" "$APP_PLIST_PATH"

APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PLIST_PATH" 2>/dev/null || true)"
if [[ -z "$APP_BUNDLE_ID" ]]; then
  echo "error: missing CFBundleIdentifier in $APP_PLIST_PATH" >&2
  exit 1
fi

sign_binary() {
  local binary_path="$1"
  local identifier="$2"
  codesign --force --sign - \
    --identifier "$identifier" \
    --requirements "=designated => identifier \"$identifier\"" \
    "$binary_path"
}

sign_binary "$APP_MACOS_PATH/$APP_NAME" "$APP_BUNDLE_ID"
sign_binary "$APP_RESOURCES_PATH/$AGENT_NAME" "$AGENT_BUNDLE_ID"
sign_binary "$APP_RESOURCES_PATH/$BUNDLED_CLI_NAME" "$CLI_BUNDLE_ID"

# Keep a stable designated requirement across local rebuilds so TCC grants
# (Accessibility etc.) are not invalidated by ad-hoc cdhash changes.
codesign --force --sign - \
  --identifier "$APP_BUNDLE_ID" \
  --requirements "=designated => identifier \"$APP_BUNDLE_ID\"" \
  "$APP_BUNDLE_PATH"

echo "Built app bundle: $APP_BUNDLE_PATH"
echo "App version: $APP_VERSION ($APP_BUILD_VERSION)"
