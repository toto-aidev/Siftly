# Siftly — macOS 写真仕分けアプリ

> このファイルは「Siftly が何で、どう作られているか」を**他の人／他のAIに一読で把握してもらう**ためのコンテキスト資料です。コードの実装方針・APIの選定理由・ハマりどころまで含めて、ここを読めば再開・改修できる状態にしてあります。

---

## 1. 何をするアプリか（概要）

Apple の **写真（Photos）アプリ** のライブラリを対象に、「**未整理**」という名前のアルバムに溜まった写真／動画を、**1枚ずつ、または複数まとめて、各アルバムへ素早く仕分ける**ための macOS ネイティブ・デスクトップアプリ。

- 行き先アルバムをクリックすると、その写真は **対象アルバムに追加され、同時に「未整理」から外れる**（＝仕分け完了）。
- Photos に新しく入った写真のうち、**どのアルバムにも分類されていないもの**を自動的に「未整理」へ取り込む。
- いわば「写真版の inbox zero」ツール。

### 基本ワークフロー
1. ユーザーは Photos に「未整理」という**手動作成の通常アルバム**を持っている。
2. Siftly はそのアルバムの中身を一覧＋プレビュー表示。
3. 写真を見て、行き先アルバムをクリック（or 複数選択して一括）→ 追加＋未整理から削除。
4. 不要な写真はゴミ箱（最近削除した項目）へ。
5. Photos に新規写真が入ると、未分類分が自動で「未整理」に補充される。

---

## 2. 技術スタック / ビルド

- **言語**: Swift 6.2、SwiftUI（UI）＋ AppKit（一部）
- **フレームワーク**: SwiftUI / Photos(PhotoKit) / AppKit / AVKit / AVFoundation / CoreLocation
- **対象 OS**: macOS 13+（開発・確認は macOS 26 "Tahoe" / Apple Silicon arm64）
- **ビルド方式**: **Xcode IDE を使わず `swiftc` で直接コンパイル**し、`.app` バンドルを手組み＋アドホック署名。
- **bundle ID**: `com.toto.siftly`
- **構成ファイル**:
  - `PhotoTriageApp.swift` … 本体（全ロジック・全UIが入った単一ファイル。約1,400行）
  - `Info.plist` … `NSPhotoLibraryUsageDescription` 等。`CFBundleExecutable=Siftly`
  - `build.sh` … `swiftc` でビルドして `build/Siftly.app` を生成＋署名
  - `install.sh` … `build.sh` 実行 → `/Applications/Siftly.app` へ再インストール
  - `build/Siftly.app` … ビルド成果物

> 注: 内部のソースファイル名・型名は旧称 `PhotoTriage` のまま（`PhotoTriageApp.swift`、`struct PhotoTriageApp`）。表示名だけ "Siftly" にリブランドした。動作上は無関係。

### ビルド & 実行
```bash
cd /path/to/siftly
./build.sh                       # build/Siftly.app を生成
open "build/Siftly.app"          # 起動
./install.sh                     # /Applications/Siftly.app に再インストール
```

### ビルド上の重要な注意
- `@main` を `swiftc` で使うため **`-parse-as-library` が必須**（無いと "main attribute cannot be used in a module that contains top-level code" エラー）。
- PhotoKit のアクセス許可ダイアログを出すには **Info.plist に `NSPhotoLibraryUsageDescription` が必要**＆**コード署名（アドホックで可）が必要**。
- 直接 `swiftc` ビルドのため、**SwiftUI の `VideoPlayer`（AVKit cross-import overlay `_AVKit_SwiftUI`）は起動時クラッシュする**（§6 参照）。AppKit の `AVPlayerView` で回避済み。

---

## 3. アーキテクチャ

単一ファイル内に「1つの ObservableObject モデル」＋「SwiftUI ビュー群」＋「AppKit ラッパー」という構成。

### 3.1 モデル: `TriageModel`
`@MainActor final class TriageModel: NSObject, ObservableObject, PHPhotoLibraryChangeObserver`

- NSObject 継承の理由 = `PHPhotoLibraryChangeObserver`（NSObjectProtocol 必須）に準拠するため。
- 主な `@Published` プロパティ:
  - `authStatus: PHAuthorizationStatus`
  - `unsortedAlbum: PHAssetCollection?` … 「未整理」アルバム
  - `assets: [PHAsset]` … 未整理の中身（creationDate 昇順）
  - `currentIndex: Int` … プレビュー中の写真の位置
  - `albums: [PHAssetCollection]` … 移動先候補（未整理以外のユーザーアルバム）
  - `currentImage: NSImage?` / `currentPlayer: AVPlayer?` / `currentIsVideo: Bool`
  - `currentLocationString: String` … 撮影場所（逆ジオコーディング結果）
  - `selectedIDs: Set<String>` … 複数選択（localIdentifier の集合）
  - `undoStack: [UndoEntry]`、`movedCount`、`isWorking`、`statusMessage`、`resetScrollTick`

### 3.2 ビュー
- `ContentView` … `authStatus` に応じて `RequestView` / `DeniedView` / `MissingAlbumView` / `DoneView` / `TriageView` を出し分け。
- `TriageView` … メイン画面。左＝プレビュー、右＝移動先アルバムパネル、下＝フィルムストリップ。
- `PlayerView`（NSViewRepresentable）… 動画再生（AppKit `AVPlayerView`）。
- `ZoomableImageView` + `FitScrollView`（NSViewRepresentable / NSScrollView 派生）… 写真のピンチ拡大＆二本指パン。
- `ThumbnailView` … フィルムストリップ用サムネイルの遅延読み込み。
- `FilmstripCell` … 一覧の1コマ（選択トグル＋プレビュー＋動画バッジ）。
- PreferenceKey: `CellFramesKey`（セル位置）、補助 struct `ScrollMetrics`。

---

## 4. 機能一覧と実装の要点（PhotoKit API）

| 機能 | 実装 |
|---|---|
| 「未整理」取得 | `PHAssetCollection.fetchAssetCollections(.album, .any)` ＋ `NSPredicate(localizedTitle == "未整理")` |
| 移動先アルバム一覧 | `.album, .albumRegular` を取得し未整理を除外、タイトル順ソート |
| 写真をアルバムへ移動 | `performChanges { addReq.addAssets() ; rmReq.removeAssets() }`（追加＝対象アルバム / 削除＝未整理） |
| 新規アルバム作成＋移動 | `PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle:)` ＋ `addAssets` |
| 複数選択 | `selectedIDs`。移動/削除は「選択があれば全部、無ければ現在の1枚」(`assetsToActOn()`) |
| Undo（Cmd+Z） | `UndoEntry`（assetIDs 配列＋albumID）。未整理へ戻し＋対象から外す。バッチも1回でまとめて取消。新規作成アルバムは取消時に空なら自動削除 |
| ゴミ箱へ | `PHAssetChangeRequest.deleteAssets()` → Photos の「最近削除した項目」（実行時にOS確認ダイアログ。アプリ内Undof対象外） |
| アルバム名変更 | `PHAssetCollectionChangeRequest(for:).title = newName` |
| 撮影日時 | `PHAsset.creationDate` を `ja_JP` で整形 |
| 撮影場所 | `PHAsset.location` を `CLGeocoder.reverseGeocodeLocation`（国/都道府県/市区町村/POI）。座標を即表示→地名に差し替え |
| 動画再生 | `imageManager.requestPlayerItem(forVideo:)` → `AVPlayer` → `AVPlayerView`(AppKit) |
| 未分類の自動取り込み | §5 参照 |

### プレビュー画像
`requestImage` を **2800px / `.opportunistic`（速報→高解像度）/ `.exact`** で取得（ズーム耐性のため高解像度）。

---

## 5. 「未分類写真の自動取り込み」ロジック（重要）

PhotoKit に「どのアルバムにも属さない写真」を直接返すクエリは無いので、差集合で求める。

```
未分類 = (ライブラリ全体 All Photos)  −  (未整理以外の全ユーザーアルバムに属する写真)  −  (すでに未整理にある写真)
```

- `computeUnclassifiedIDs(unsortedID:)`（`nonisolated static`）で算出。**重い列挙なので `Task.detached(.utility)` でバックグラウンド実行**（メインスレッドを塞がない）。
- ライブラリ全体 = `.smartAlbum, .smartAlbumUserLibrary`（All Photos）。
- 求めた未分類を `performChanges` で「未整理」へ `addAssets`。
- **自動化**: `PHPhotoLibraryChangeObserver.photoLibraryDidChange` を受けて `libraryChanged()` → **0.8秒デバウンス**して `importUnclassified` を実行（自分の移動操作が生む変更通知の連打を吸収）。アプリ起動時にも1回実行。

> 注意: スマートアルバム/ピープル等"しか"入っていない写真は「未分類」とみなして取り込む（通常のユーザーアルバム所属のみを"分類済み"とする）。

---

## 6. 設計上の落とし穴（既知の知見・触る前に読む）

1. **SwiftUI `VideoPlayer` は使わない** — `swiftc` 直ビルドだと AVKit の cross-import overlay `_AVKit_SwiftUI` の型メタデータ解決に失敗し、**起動時に SIGABRT クラッシュ**（`getSuperclassMetadata` で fatalError）。AppKit の `AVPlayerView` を `NSViewRepresentable` でラップして回避済み（`PlayerView`）。
   - 症状の罠: GUI 起動時だけクラッシュし、ターミナルから実行ファイル直叩きでは `.onAppear` が走らず再現しない。クラッシュログは `~/Library/Logs/DiagnosticReports/`。
2. **写真のズーム/パンは NSScrollView でやる** — SwiftUI の `MagnifyGesture`+`DragGesture` だと「二本指スワイプでのパン」がしづらく、軸ロックでカクつく。`NSScrollView(allowsMagnification)` ＋ **`usesPredominantAxisScrolling = false`**（斜め移動許可）でネイティブのピンチ拡大＋二本指パンを実現（`ZoomableImageView`/`FitScrollView`）。
3. **サムネイル画質** — `.fastFormat`+`.fast` は粗い。`.opportunistic`+`.exact`＋Retina解像度で取得する。
4. **フィルムストリップのドラッグ範囲選択＋端での自動スクロール** — `ScrollPosition`（`scrollTo(x:)`/`scrollTo(edge:)`）＋ `onScrollGeometryChange` でオフセットを連続制御。「コマ送り」だと同一セルに張り付いて止まるバグがあったため、毎フレーム微小オフセット移動の連続スクロール方式にしている。範囲選択は「開始セル〜現在セル」を塗り、戻すと範囲外は開始時の状態へ復元。
5. **重いPhotoKit列挙はメインスレッドに置かない**（§5）。起動・移動のたびに全ライブラリ走査するとプレビュー読み込みが詰まる。
6. **`CLGeocoder` は macOS 26 で deprecated**（MapKit 推奨）。現状は動作する。将来 `MKReverseGeocodingRequest` へ移行余地あり。
7. **「未整理」は手動作成の通常アルバム前提**。スマートアルバムだと PhotoKit で写真を削除できない（仕分けの"未整理から外す"が成立しない）。
8. **bundle ID を変えると TCC 上は別アプリ扱い** → 初回に Photos 許可ダイアログが再表示される。

---

## 7. 現在の状態 / 今後の候補

- 状態: 機能的に完成。ユーザー評価「完璧」。`/Applications/Siftly.app` にインストール済み。
- リブランド: 旧称「写真仕分け / PhotoTriage」→ 公開名 **Siftly**（造語、英語圏想定）。表示名・ウィンドウタイトル・bundle ID・.app名を更新済み（ソース内の型名は PhotoTriage のまま）。
- 公開に向けた未了タスク:
  - **アプリアイコン未設定**（汎用アイコン）。1024×1024 から `.icns` 生成して `Info.plist`(`CFBundleIconFile`)＋`Resources/` に組み込む必要あり。
  - **"Siftly" の商標／App Store 名の空き確認**。
  - **配布形態の決定**: Mac App Store 申請 or 署名＋公証(notarize)した `.dmg` 直配布。直配布なら Developer ID 署名＋notarization が必要（現状はアドホック署名）。

---

## 8. 章立て（ソース内の MARK 目印）

`PhotoTriageApp.swift` 内の主な区切り:
- `// MARK: - Model`（`UndoEntry` / `TriageModel`）
- Authorization / Loading / 未分類写真の取り込み / Navigation / Move operations / アルバム名の変更 / Delete / Undo / Selection / 端での連続自動スクロール
- `// MARK: - Root View`（`ContentView`）
- `// MARK: - Triage View`（`TriageView` … 本体UI）
- `// MARK: - 動画プレイヤー`（`PlayerView`）
- `// MARK: - 拡大できる写真ビュー`（`FitScrollView` / `ZoomableImageView`）
- `// MARK: - Filmstrip components`（`ThumbnailView` / `FilmstripCell` / `CellFramesKey` / `ScrollMetrics`）
- `// MARK: - Auxiliary Views`（`RequestView` / `DeniedView` / `MissingAlbumView` / `DoneView`）
- `// MARK: - App`（`@main struct PhotoTriageApp`）
