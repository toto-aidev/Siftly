#!/bin/bash
# 再ビルドして /Applications にインストールし直す
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_NAME="Siftly"
APP="build/$BUNDLE_NAME.app"
DEST="/Applications/$BUNDLE_NAME.app"

echo "==> ビルド"
./build.sh

echo "==> 起動中なら終了"
osascript -e "tell application \"$BUNDLE_NAME\" to quit" 2>/dev/null || true
sleep 1

echo "==> /Applications へインストール"
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "==> 完了: $DEST"
echo "    起動:  open \"$DEST\""
