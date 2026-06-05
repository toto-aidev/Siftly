#!/bin/bash
# icon-source.png を編集した後にこのスクリプトを実行すれば、
# .icns・Asset catalog の全サイズ・Siftly.app への反映までまとめて行う。
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f icon-source.png ]; then
	echo "❌ icon-source.png が見つかりません"; exit 1
fi

echo "==> 1. AppIcon.icns を再生成"
./make_icon.sh

echo "==> 2. Asset catalog の各サイズを再生成"
ASSET="Assets.xcassets/AppIcon.appiconset"
gen() { sips -z "$2" "$2" icon-source.png --out "$ASSET/$1" >/dev/null; }
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
echo "✅ Asset catalog 更新"

echo "==> 3. Siftly を終了して再インストール"
osascript -e 'tell application "Siftly" to quit' 2>/dev/null || true
sleep 1
./install.sh

echo "==> 4. アイコンキャッシュ更新（Dock/Finder 再起動）"
killall Dock Finder 2>/dev/null || true

echo "==> 5. 起動"
open "/Applications/Siftly.app"
echo "✅ アイコン適用完了"
