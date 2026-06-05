# Siftly アイコン — macOS 26「アイコンとウィジェットのスタイル」追従ガイド

このガイドは、Siftly のアプリアイコンを macOS 26（Tahoe）の **アイコンとウィジェットのスタイル**（デフォルト／ダーク／クリア（明）／クリア（暗）／ティント）に追従させるための手順書です。

> **このガイドの前提**：Xcode 26 をインストール済みであること（無料／App Store または developer.apple.com から）。

---

## ステップ0：Xcode 26 のインストール完了確認

ターミナルで以下を実行：
```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcrun --find actool
xcrun --find icon-composer 2>/dev/null || ls /Applications/Xcode.app/Contents/Applications/Icon\ Composer.app 2>/dev/null || echo "Icon Composer は Xcode → Developer Tool または別途検索"
```

`actool` のパスが返れば OK。Icon Composer は **Xcode のメニュー → Developer Tool → Icon Composer** から、または `/Applications/Xcode.app/Contents/Applications/Icon Composer.app` を Spotlight で起動。

---

## ステップ1：Icon Composer でアイコンを作る

1. **Icon Composer を起動** → 「**New Document**」
2. アイコンの**レイヤー構造**を作る。Siftly のアイコンは以下の3層に分けるのが自然：

   | レイヤー | 内容 | 用途 |
   |---|---|---|
   | **背景（Background）** | 青いトレイ＋クリーム色背景 | クリア/ティント時に色味の土台 |
   | **中間（Mid）** | 3枚の写真カード | 主要なビジュアル |
   | **前景（Foreground）** | 緑のチェックマーク | 完了感のアクセント |

3. **元画像の取り込み**：プロジェクトの `icon-source.png`（1254×1254）をベースに、Photoshop / Affinity / Figma などで各レイヤーを**透過 PNG**で書き出してから Icon Composer に読み込むのが現実的です（1024×1024 推奨）。
   - 背景レイヤー：トレイ＋背景（前景・中間を消した状態）
   - 中間レイヤー：写真3枚だけ（透過）
   - 前景レイヤー：チェックマークだけ（透過）

4. **モード別の見え方を確認**：Icon Composer 上部のモード切替で **Default / Dark / Clear (Light) / Clear (Dark) / Tinted** を切り替えながらプレビュー。Icon Composer が**自動でモード別の見え方を生成**してくれますが、必要なら**レイヤーの不透明度・色**を各モードで調整できます。

5. **書き出し**：File → Export →
   - **`Siftly.icon`** という名前で、プロジェクトの `Assets.xcassets/` 配下に書き出し（フォルダ構造: `Assets.xcassets/AppIcon.icon/`）。
   - ※ 旧形式の `AppIcon.appiconset` フォルダが既にありますが**そのまま残してOK**（Xcode 25 以前と互換）。`AppIcon.icon` の方があれば actool は新形式を優先します。

---

## ステップ2：ビルド＆インストール

プロジェクトのターミナルで：
```bash
cd /path/to/siftly
./install.sh
```

`build.sh` は自動で `actool` を検出し、`Assets.xcassets` をコンパイルして `Assets.car` をバンドルに同梱します。**Xcode 不在時は従来の `.icns` にフォールバック**するので、もし Xcode を削除しても build.sh は壊れません。

---

## ステップ3：動作確認

1. システム設定 → **外観** → **アイコンとウィジェットのスタイル**（デフォルト／ダーク／クリア／ティント）を切り替え。
2. Dock や Launchpad の Siftly アイコンが**モードに応じて変化**すれば成功。

> 反映が鈍い場合は `killall Dock Finder` でアイコンキャッシュを更新。

---

## トラブルシューティング

| 症状 | 原因 | 対処 |
|---|---|---|
| `actool` が見つからない | Xcode が CommandLineTools 扱い | `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer` |
| `Icon Composer` が見つからない | Xcode 内アプリ | Spotlight で「Icon Composer」検索 or Xcode メニュー → Developer Tool |
| 切り替えても変わらない | アイコンキャッシュ | `killall Dock Finder`、それでも変わらなければ再ログイン |
| バンドルに Assets.car が無い | `actool` の検出失敗 | `build.sh` を再実行、出力ログで「アセットカタログをコンパイル」が出るか確認 |
| 旧アイコンが残る | TCC/LaunchServices 二重登録 | `/Applications/Siftly.app` を削除して再 `./install.sh` |

---

## 参考：レイヤー分割画像が用意できない場合の最短ルート

Icon Composer は**単一画像でも開けます**。その場合は：
1. `icon-source.png` をそのまま Icon Composer に読み込み
2. Default のみ設定して書き出し → Dark/Clear/Tinted は**自動生成された見え方**で妥協

完全追従ではないものの、新形式バンドルとして配布されるため、将来レイヤー分割版に差し替えるだけでスタイル追従が完成します。

---

## ファイル配置の最終形（参考）

```
写真仕分け/
├── PhotoTriageApp.swift
├── Info.plist
├── build.sh                     ← actool 自動検出
├── install.sh
├── icon-source.png              ← 元画像（保管用）
├── AppIcon.icns                 ← 旧形式フォールバック
├── make_icon.sh                 ← icon-source.png → AppIcon.icns
└── Assets.xcassets/
    ├── Contents.json
    ├── AppIcon.appiconset/      ← 旧形式（互換用、削除可）
    │   ├── Contents.json
    │   └── icon_*.png
    └── AppIcon.icon/            ← ★ Icon Composer の出力（要作成）
        └── ...
```

---

## 補足：2026-06-05 の検証結果（重要）

- Icon Composer で `.icon` ファイルを作成し `Assets.xcassets/AppIcon.icon` に配置 → **`actool` 直接呼びでは認識されない**（警告もエラーも出ず無視）ことを確認。
- 確実に新形式アイコンを組み込むには **Xcode プロジェクト（`.xcodeproj`）化して `xcodebuild` でビルド**する必要がある（推定）。
- 現状は `AppIcon.appiconset`（旧形式）→ `Assets.car` 経路で動作中。
- 作成済みの `AppIcon.icon` は将来用に保持。Xcode プロジェクト化を実施した時に再利用可。
