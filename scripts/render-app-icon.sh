#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
ICON_DOCUMENT="$ROOT/Resources/AppIcon.icon"
ICON_TOOL="${ICON_COMPOSER_TOOL:-/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool}"
OUTPUT_PNG="$ROOT/Resources/AppIcon.png"
OUTPUT_ICNS="$ROOT/Resources/AppIcon.icns"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi
if [[ ! -d "$ICON_DOCUMENT" || ! -f "$ICON_DOCUMENT/icon.json" ]]; then
  print -u2 "Icon Composer document is missing: $ICON_DOCUMENT"
  exit 1
fi
if [[ ! -x "$ICON_TOOL" ]]; then
  print -u2 "Icon Composer command-line tool is unavailable: $ICON_TOOL"
  exit 1
fi

STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sayall-app-icon-render.XXXXXX")"
trap 'rm -rf -- "$STAGING_ROOT"' EXIT
MASTER_PNG="$STAGING_ROOT/AppIcon.png"
ICONSET="$STAGING_ROOT/AppIcon.iconset"
MASTER_ICNS="$STAGING_ROOT/AppIcon.icns"

"$ICON_TOOL" "$ICON_DOCUMENT" \
  --export-image \
  --output-file "$MASTER_PNG" \
  --platform macOS \
  --rendition Default \
  --width 1024 \
  --height 1024 \
  --scale 1

mkdir -p "$ICONSET"
typeset -a ICON_RENDITIONS=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)
for rendition in "${ICON_RENDITIONS[@]}"; do
  name="${rendition%%:*}"
  size="${rendition##*:}"
  /usr/bin/sips -z "$size" "$size" "$MASTER_PNG" \
    --out "$ICONSET/$name" >/dev/null
done
/usr/bin/iconutil --convert icns --output "$MASTER_ICNS" "$ICONSET"

/usr/bin/install -m 0644 "$MASTER_PNG" "$OUTPUT_PNG"
/usr/bin/install -m 0644 "$MASTER_ICNS" "$OUTPUT_ICNS"
print "Rendered $OUTPUT_PNG"
print "Rendered $OUTPUT_ICNS"
