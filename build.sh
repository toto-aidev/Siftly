#!/bin/bash
# Siftly のビルドスクリプト
# 使い方:  ./build.sh        → build/Siftly.app を生成
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Siftly"               # 実行ファイル名（Info.plist の CFBundleExecutable と一致）
BUNDLE_NAME="Siftly"            # .app の表示名
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$BUNDLE_NAME.app"

echo "==> クリーン"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

echo "==> コンパイル (swiftc)"
swiftc -O -parse-as-library \
	-framework SwiftUI -framework Photos -framework AppKit \
	-o "$APP_DIR/Contents/MacOS/$APP_NAME" \
	PhotoTriageApp.swift

echo "==> バンドル構成"
cp Info.plist "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# アイコン: Xcode（actool）があれば Assets.xcassets をコンパイル
# （新形式 AppIcon.icon を入れればスタイル追従が効く）
# 無ければ従来の AppIcon.icns をコピー
ACTOOL="$(xcrun --find actool 2>/dev/null || true)"
if [ -n "$ACTOOL" ] && [ -d Assets.xcassets ]; then
	echo "==> アセットカタログをコンパイル (actool)"
	"$ACTOOL" Assets.xcassets \
		--compile "$APP_DIR/Contents/Resources" \
		--platform macosx \
		--minimum-deployment-target 13.0 \
		--app-icon AppIcon \
		--output-partial-info-plist "$BUILD_DIR/_partial_info.plist" \
		--errors --warnings >/dev/null
	# 部分 plist を Info.plist にマージ（CFBundleIcon* の設定を引き継ぐ）
	if [ -f "$BUILD_DIR/_partial_info.plist" ]; then
		/usr/libexec/PlistBuddy -c "Merge $BUILD_DIR/_partial_info.plist" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
		rm -f "$BUILD_DIR/_partial_info.plist"
	fi
elif [ -f AppIcon.icns ]; then
	echo "==> 従来アイコン (.icns) を組み込み"
	cp AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

echo "==> アドホック署名"
codesign --force --deep --sign - "$APP_DIR"

echo "==> 完了: $APP_DIR"
echo "    起動:  open \"$APP_DIR\""
