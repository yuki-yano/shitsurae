#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_DIR="$ROOT_DIR/Shitsurae/Assets.xcassets"
ASSET_SOURCES_DIR="$ROOT_DIR/Shitsurae/AssetSources"
APP_ICONSET_DIR="$ASSETS_DIR/AppIcon.appiconset"
MENU_ICONSET_DIR="$ASSETS_DIR/MenuBarIcon.imageset"

SOURCE_APP_ICON="$ASSET_SOURCES_DIR/icon.png"
SOURCE_MENU_ICON="$ASSET_SOURCES_DIR/menubar-icon-template.svg"

mkdir -p "$APP_ICONSET_DIR" "$MENU_ICONSET_DIR"

if [[ ! -f "$SOURCE_APP_ICON" ]]; then
  echo "missing source: $SOURCE_APP_ICON" >&2
  exit 1
fi

if [[ ! -f "$SOURCE_MENU_ICON" ]]; then
  echo "missing source: $SOURCE_MENU_ICON" >&2
  exit 1
fi

# App icon sizes for macOS app icon set.
declare -a ICONS=(
  "16:16"
  "16@2x:32"
  "32:32"
  "32@2x:64"
  "128:128"
  "128@2x:256"
  "256:256"
  "256@2x:512"
  "512:512"
  "512@2x:1024"
)

for entry in "${ICONS[@]}"; do
  name="${entry%%:*}"
  size="${entry##*:}"
  out="$APP_ICONSET_DIR/icon_${name}.png"
  sips -s format png -z "$size" "$size" "$SOURCE_APP_ICON" --out "$out" >/dev/null
  echo "generated $out"
done

for entry in "22:22" "44:44"; do
  name="${entry%%:*}"
  size="${entry##*:}"
  out="$MENU_ICONSET_DIR/menu-${name}.png"
  sips -s format png -z "$size" "$size" "$SOURCE_MENU_ICON" --out "$out" >/dev/null
  echo "generated $out"
done

cat > "$APP_ICONSET_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

cat > "$MENU_ICONSET_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "menu-22.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "menu-44.png", "idiom" : "mac", "scale" : "2x" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}
JSON
