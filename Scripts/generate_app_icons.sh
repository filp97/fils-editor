#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$SCRIPT_DIR/../fil's editor/Assets.xcassets/AppIcon.appiconset"
LIGHT="$SCRIPT_DIR/AppIcon-light-master.png"

if [[ ! -f "$LIGHT" ]]; then
  echo "Manca AppIcon-light-master.png in Scripts/" >&2
  exit 1
fi

# Solo slot light: actool macOS non assegna le varianti dark nel formato multi-size.
rm -f "$DEST"/*.png

make_square_1024() {
  local src="$1"
  local out="$2"
  local w h min
  w=$(sips -g pixelWidth "$src" | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$src" | awk '/pixelHeight/{print $2}')
  min=$(( w < h ? w : h ))
  sips -c "$min" "$min" "$src" --out "${out}.tmp.png" >/dev/null
  sips -z 1024 1024 "${out}.tmp.png" --out "$out" >/dev/null
  rm -f "${out}.tmp.png"
}

MASTER="$DEST/.master-1024.png"
make_square_1024 "$LIGHT" "$MASTER"

declare -a specs=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)

for spec in "${specs[@]}"; do
  size="${spec%%:*}"
  file="${spec##*:}"
  sips -z "$size" "$size" "$MASTER" --out "$DEST/$file" >/dev/null
  echo "Scritto $file (${size}px)"
done

rm -f "$MASTER"
echo "Fatto. Master dark opzionale: Scripts/AppIcon-dark-master.png"
