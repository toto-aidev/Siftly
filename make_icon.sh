#!/bin/bash
# icon-source.png (正方形・1024px以上推奨) から AppIcon.icns を生成する
set -euo pipefail
cd "$(dirname "$0")"

SRC="icon-source.png"
ICONSET="AppIcon.iconset"
OUT="AppIcon.icns"

[ -f "$SRC" ] || { echo "❌ $SRC がありません"; exit 1; }

rm -rf "$ICONSET" "$OUT"
mkdir -p "$ICONSET"

# macOS が要求する各サイズを生成
gen() { sips -z "$2" "$2" "$SRC" --out "$ICONSET/$1" >/dev/null; }
gen icon_16x16.png        16
gen icon_16x16@2x.png     32
gen icon_32x32.png        32
gen icon_32x32@2x.png     64
gen icon_128x128.png      128
gen icon_128x128@2x.png   256
gen icon_256x256.png      256
gen icon_256x256@2x.png   512
gen icon_512x512.png      512
gen icon_512x512@2x.png   1024

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"
echo "✅ $OUT を生成しました"
