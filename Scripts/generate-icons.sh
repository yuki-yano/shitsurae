#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_DIR="$ROOT_DIR/Shitsurae/Assets.xcassets"
APP_ICONSET_DIR="$ASSETS_DIR/AppIcon.appiconset"
MENU_ICONSET_DIR="$ASSETS_DIR/MenuBarIcon.imageset"

SOURCE_APP_ICON="$ROOT_DIR/docs/icon.png"
SOURCE_MENU_16="$ROOT_DIR/docs/menubar-icon-template-16.png"
SOURCE_MENU_32="$ROOT_DIR/docs/menubar-icon-template-32.png"

mkdir -p "$APP_ICONSET_DIR" "$MENU_ICONSET_DIR"

if [[ ! -f "$SOURCE_APP_ICON" ]]; then
  echo "missing source: $SOURCE_APP_ICON" >&2
  exit 1
fi

if [[ ! -f "$SOURCE_MENU_16" || ! -f "$SOURCE_MENU_32" ]]; then
  echo "missing source: menubar icon templates" >&2
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

cp "$SOURCE_MENU_16" "$MENU_ICONSET_DIR/menu-16.png"
cp "$SOURCE_MENU_32" "$MENU_ICONSET_DIR/menu-32.png"

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
    { "filename" : "menu-16.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "menu-32.png", "idiom" : "mac", "scale" : "2x" }
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
