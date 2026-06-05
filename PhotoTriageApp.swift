import SwiftUI
import Photos
import AppKit
import CoreLocation
import AVKit
import AVFoundation

// MARK: - Model

/// 取り消し1回分の記録（バッチ移動も1回でまとめて取り消せるよう複数ID保持）
struct UndoEntry {
    let assetIDs: [String]
    let albumID: String                  // 追加先アルバム
    let albumTitle: String
    let wasNewlyCreated: Bool
    /// 仕分け元アルバム（Undo 時に「戻す」先）
    let sourceAlbumID: String?
    let sourceAlbumTitle: String
    /// この操作で元アルバムから写真を取り除いたか
    let wasRemovedFromSource: Bool
}

@MainActor
final class TriageModel: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var authStatus: PHAuthorizationStatus = .notDetermined
    @Published var unsortedAlbum: PHAssetCollection?
    @Published var pendingDeleteAlbum: PHAssetCollection?
    @Published var pendingDeleteCount: Int = 0
    /// 仕分け元アルバム（nil = 未整理）
    @Published var sourceAlbum: PHAssetCollection?
    /// 「未整理以外」を仕分けるとき、元のアルバムから写真を取り除くか（未整理は常に取り除く）
    @Published var removeFromSource: Bool = true
    @Published var assets: [PHAsset] = []
    @Published var currentIndex: Int = 0
    @Published var albums: [PHAssetCollection] = []
    @Published var currentImage: NSImage?
    @Published var currentPlayer: AVPlayer?
    @Published var currentIsVideo = false
    @Published var currentIsFavorite = false
    @Published var currentLocationString: String = ""
    @Published var statusMessage: String = ""
    @Published var isWorking = false
    @Published var isReloading = false
    @Published var isImporting = false
    @Published var movedCount = 0
    @Published var undoStack: [UndoEntry] = []
    @Published var redoStack: [UndoEntry] = []
    @Published var selectedIDs: Set<String> = []

    var canUndo: Bool { !undoStack.isEmpty }
    var lastUndoTitle: String? { undoStack.last?.albumTitle }
    var canRedo: Bool { !redoStack.isEmpty }
    var lastRedoTitle: String? { redoStack.last?.albumTitle }
    var selectedCount: Int { selectedIDs.count }

    // MARK: ソースアルバム関連
    /// 実際の仕分け元（nil なら未整理にフォールバック）
    var effectiveSourceAlbum: PHAssetCollection? { sourceAlbum ?? unsortedAlbum }
    /// ソースが未整理か（このときは removeFromSource=true 固定で UI のトグル非表示）
    var isSourceUnsorted: Bool {
        let id = sourceAlbum?.localIdentifier ?? unsortedAlbum?.localIdentifier
        return id == unsortedAlbum?.localIdentifier
    }
    /// 実際に削除するかどうか
    var shouldRemoveFromSource: Bool { isSourceUnsorted || removeFromSource }
    var sourceAlbumTitle: String { effectiveSourceAlbum?.localizedTitle ?? unsortedAlbumTitle }

    /// 操作対象：選択があればその全部、無ければ現在の1枚
    private func assetsToActOn() -> [PHAsset] {
        if !selectedIDs.isEmpty {
            return assets.filter { selectedIDs.contains($0.localIdentifier) }
        }
        if let c = currentAsset { return [c] }
        return []
    }

    // MARK: Selection

    func setCurrent(_ asset: PHAsset) {
        if let idx = assets.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) {
            currentIndex = idx
            loadCurrentImage()
        }
    }

    func toggleSelection(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    func selectAll() { selectedIDs = Set(assets.map { $0.localIdentifier }) }
    func clearSelection() { selectedIDs.removeAll() }
    func isSelected(_ asset: PHAsset) -> Bool { selectedIDs.contains(asset.localIdentifier) }

    // ドラッグ選択用：localIdentifier 直指定
    func setSelected(_ id: String, _ selected: Bool) {
        if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
    }
    func setCurrentByID(_ id: String) {
        if let idx = assets.firstIndex(where: { $0.localIdentifier == id }) {
            currentIndex = idx
            loadCurrentImage()
        }
    }

    /// 仕分け元アルバム名。必要なら変更可。
    let unsortedAlbumTitle = "未整理"
    let pendingDeleteAlbumTitle = "削除予定"

    private let imageManager = PHImageManager.default()
    private var imageRequestID: PHImageRequestID?
    /// 先読み用：現在の前後数枚をバックグラウンドでメモリにキャッシュしておく
    private let cachingManager = PHCachingImageManager()
    private var cachedAssetIDs: Set<String> = []
    private let cacheRange = 10
    private let cacheTargetSize = CGSize(width: 2800, height: 2800)
    /// オプションは毎回作らずシングルトン的に共有（インスタンス差で PhotoKit がキャッシュをミスする回避）
    private static let sharedImageOptions: PHImageRequestOptions = {
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast   // .exact よりわずかに高速。視覚差はほぼ無い
        return opts
    }()
    private var cacheImageOptions: PHImageRequestOptions { Self.sharedImageOptions }
    private let geocoder = CLGeocoder()
    private var locationToken = 0
    private var observerRegistered = false
    private var libraryChangeTask: Task<Void, Never>?
    /// 復活防止：移動／削除した直後の写真IDを一定時間「未分類取り込み」の対象外にする
    /// （key=localIdentifier / value=除外解除時刻）
    private var recentlyMovedIDs: [String: Date] = [:]
    private let recentlyMovedTTL: TimeInterval = 300   // 5分間

    override init() {
        super.init()
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    private func registerObserverIfNeeded() {
        guard !observerRegistered else { return }
        PHPhotoLibrary.shared().register(self)
        observerRegistered = true
    }

    // ライブラリ変更通知（任意スレッドで呼ばれる）
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.libraryChanged() }
    }

    private func libraryChanged() {
        guard authStatus == .authorized || authStatus == .limited, unsortedAlbum != nil else { return }
        // 連続する変更（自分の移動操作・iCloud 同期）をまとめる：最後の変更から4秒後に1回だけ走査。
        // 長めに取ることで余計な再フェッチ／再描画を抑制する（loadAssets 内で差分が無ければスキップ）。
        libraryChangeTask?.cancel()
        libraryChangeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return }
            guard !self.isWorking else { return }
            self.loadPendingDeleteAlbum()
            if self.isSourceUnsorted {
                self.importUnclassified(announce: false, preservePosition: true)
            } else {
                self.loadAssets(preservePosition: true)
            }
        }
    }

    /// 移動／削除した写真IDを「最近移動した」リストに登録（一定時間、自動取り込みから除外）
    private func markMoved(_ ids: [String]) {
        let expire = Date().addingTimeInterval(recentlyMovedTTL)
        for id in ids { recentlyMovedIDs[id] = expire }
        pruneRecentlyMoved()
    }

    /// 期限切れエントリの掃除
    private func pruneRecentlyMoved() {
        let now = Date()
        recentlyMovedIDs = recentlyMovedIDs.filter { $0.value > now }
    }

    var currentAsset: PHAsset? {
        guard currentIndex >= 0 && currentIndex < assets.count else { return nil }
        return assets[currentIndex]
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日(E) HH:mm"
        return f
    }()

    /// 現在表示中の写真の撮影日時（無ければプレースホルダー）
    var currentDateString: String {
        guard let date = currentAsset?.creationDate else { return "撮影日時 不明" }
        return Self.dateFormatter.string(from: date)
    }

    // MARK: Authorization

    func checkAuth() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authStatus = status
        if status == .authorized || status == .limited {
            loadEverything()
        }
    }

    func requestAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            Task { @MainActor in
                self.authStatus = status
                if status == .authorized || status == .limited {
                    self.loadEverything()
                }
            }
        }
    }

    // MARK: Loading

    func loadEverything() {
        loadUnsortedAlbum()
        loadPendingDeleteAlbum()
        loadTargetAlbums()
        registerObserverIfNeeded()
        loadAssets()
        importUnclassified(announce: false, preservePosition: true)
    }

    /// 自動取り込みを伴わない単純な再読み込み（最新の Photos の状態を取り直す）
    func reloadAll() {
        guard !isReloading else { return }
        isReloading = true
        statusMessage = "最新の状態を読み込み中…"
        // スピナー描画機会を与えるため次ランループで処理を実行
        Task { @MainActor in
            self.loadUnsortedAlbum()
            self.loadPendingDeleteAlbum()
            self.loadTargetAlbums()
            self.loadAssets(preservePosition: true)
            self.isReloading = false
            self.statusMessage = "最新の状態を読み込みました。"
        }
    }

    private func loadUnsortedAlbum() {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "localizedTitle == %@", unsortedAlbumTitle)
        let res = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: opts)
        unsortedAlbum = res.firstObject
        if unsortedAlbum == nil {
            statusMessage = "「\(unsortedAlbumTitle)」という名前のアルバムが見つかりませんでした。"
        }
    }

    /// 「削除予定」アルバムを取得（無ければ nil。初回利用時に作成される）
    func loadPendingDeleteAlbum() {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "localizedTitle == %@", pendingDeleteAlbumTitle)
        let res = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: opts)
        pendingDeleteAlbum = res.firstObject
        if let album = pendingDeleteAlbum {
            pendingDeleteCount = PHAsset.fetchAssets(in: album, options: nil).count
        } else {
            pendingDeleteCount = 0
        }
    }

    func loadTargetAlbums() {
        var result: [PHAssetCollection] = []
        let res = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        res.enumerateObjects { col, _, _ in result.append(col) }
        let unsortedID = unsortedAlbum?.localIdentifier
        let pendingID = pendingDeleteAlbum?.localIdentifier
        let sourceID = effectiveSourceAlbum?.localIdentifier
        albums = result
            .filter {
                $0.localIdentifier != unsortedID
                && $0.localIdentifier != pendingID
                && $0.localIdentifier != sourceID    // 現在のソースは移動先候補から除外
            }
            .sorted { ($0.localizedTitle ?? "") < ($1.localizedTitle ?? "") }
    }

    /// ソースとして選択可能なアルバム一覧（移動先と違って、未整理は別枠で扱うので除外。削除予定も除外）
    func availableSourceAlbums() -> [PHAssetCollection] {
        var result: [PHAssetCollection] = []
        let res = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        res.enumerateObjects { col, _, _ in result.append(col) }
        let unsortedID = unsortedAlbum?.localIdentifier
        let pendingID = pendingDeleteAlbum?.localIdentifier
        return result
            .filter { $0.localIdentifier != unsortedID && $0.localIdentifier != pendingID }
            .sorted { ($0.localizedTitle ?? "") < ($1.localizedTitle ?? "") }
    }

    /// ソースアルバムを切り替える（未整理に戻すには nil を渡す）
    func setSourceAlbum(_ album: PHAssetCollection?) {
        sourceAlbum = album
        if isSourceUnsorted { removeFromSource = true } // 未整理時はトグル意味なし、デフォルトに戻す
        selectedIDs.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        currentIndex = 0
        resetImageCache()   // 別アルバムなので前ソースの先読みは全部解放
        loadTargetAlbums()
        loadAssets()
        statusMessage = "ソース：「\(sourceAlbumTitle)」に切り替えました。"
    }

    func loadAssets(preservePosition: Bool = false) {
        guard let album = effectiveSourceAlbum else { assets = []; return }
        let curID = preservePosition ? currentAsset?.localIdentifier : nil
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let res = PHAsset.fetchAssets(in: album, options: opts)
        var arr: [PHAsset] = []
        res.enumerateObjects { a, _, _ in arr.append(a) }

        // 内容に変化なし → 何もしない（不要な再描画・画像再読込を防ぐ）
        let newIDs = arr.map { $0.localIdentifier }
        let oldIDs = assets.map { $0.localIdentifier }
        if preservePosition && newIDs == oldIDs {
            return
        }

        assets = arr
        if let curID, let idx = arr.firstIndex(where: { $0.localIdentifier == curID }) {
            currentIndex = idx                                   // 仕分け中の位置を維持
        } else {
            currentIndex = preservePosition ? min(currentIndex, max(arr.count - 1, 0)) : 0
        }
        // 一覧から消えたIDは選択から除外
        let present = Set(arr.map { $0.localIdentifier })
        selectedIDs.formIntersection(present)
        loadCurrentImage()
    }

    // MARK: 未分類写真の取り込み

    /// どのアルバムにも分類されていない写真を「未整理」へ追加する。
    /// - announce: 追加0枚でもステータスに表示するか（手動更新=true / 自動=false）
    /// - preservePosition: 取り込み後に仕分け位置を維持するか
    ///
    /// 重い走査（全アルバム＋全写真）はバックグラウンドで行い、メインスレッド
    /// （＝画像の読み込みやUI）を塞がないようにする。
    func importUnclassified(announce: Bool = true, preservePosition: Bool = false) {
        guard let unsorted = unsortedAlbum, !isWorking, !isImporting else { return }
        let unsortedID = unsorted.localIdentifier
        let title = unsortedAlbumTitle
        pruneRecentlyMoved()
        let exclude = Set(recentlyMovedIDs.keys)
        // 取り込みの「ライブラリ走査中」と「追加中」両方をまとめて isImporting で表示
        isImporting = true
        if announce { statusMessage = "ライブラリを走査中…" }

        Task { [weak self] in
            let toAddIDs = await Task.detached(priority: .utility) {
                TriageModel.computeUnclassifiedIDs(unsortedID: unsortedID, exclude: exclude)
            }.value

            guard let self else { return }
            guard !toAddIDs.isEmpty else {
                self.isImporting = false
                if announce {
                    self.statusMessage = "新たに「\(title)」へ取り込む写真はありませんでした。"
                }
                return
            }

            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: toAddIDs, options: nil)
            var toAdd: [PHAsset] = []
            fetch.enumerateObjects { a, _, _ in toAdd.append(a) }
            guard !toAdd.isEmpty, !self.isWorking else { self.isImporting = false; return }

            self.isWorking = true
            self.statusMessage = "\(toAdd.count) 枚を「\(title)」へ追加中…"
            let count = toAdd.count
            PHPhotoLibrary.shared().performChanges {
                if let addReq = PHAssetCollectionChangeRequest(for: unsorted) {
                    addReq.addAssets(toAdd as NSArray)
                }
            } completionHandler: { success, error in
                Task { @MainActor in
                    self.isWorking = false
                    self.isImporting = false
                    if success {
                        self.loadAssets(preservePosition: preservePosition)
                        self.statusMessage = "未分類の写真 \(count) 枚を「\(title)」へ取り込みました。"
                    } else if announce {
                        self.statusMessage = "取り込み失敗: \(error?.localizedDescription ?? "不明なエラー")"
                    }
                }
            }
        }
    }

    /// 未分類写真のIDを算出する重い処理（バックグラウンド専用・メイン状態に触れない）
    /// - exclude: 「最近移動した／削除した」等の理由で未整理に戻したくないID
    nonisolated static func computeUnclassifiedIDs(unsortedID: String, exclude: Set<String> = []) -> [String] {
        var classified = exclude   // 既知の「復活させない」IDも分類済み扱いにする
        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        userAlbums.enumerateObjects { col, _, _ in
            if col.localIdentifier == unsortedID { return }
            PHAsset.fetchAssets(in: col, options: nil).enumerateObjects { a, _, _ in
                classified.insert(a.localIdentifier)
            }
        }
        // すでに「未整理」にある写真も再追加対象から除外
        let unsortedCols = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [unsortedID], options: nil)
        if let unsorted = unsortedCols.firstObject {
            PHAsset.fetchAssets(in: unsorted, options: nil).enumerateObjects { a, _, _ in
                classified.insert(a.localIdentifier)
            }
        }
        // ライブラリ全体（All Photos）との差分＝未分類
        var result: [String] = []
        let smart = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil)
        if let library = smart.firstObject {
            PHAsset.fetchAssets(in: library, options: nil).enumerateObjects { a, _, _ in
                if !classified.contains(a.localIdentifier) {
                    result.append(a.localIdentifier)
                }
            }
        }
        return result
    }

    func loadCurrentImage() {
        // currentImage は意図的に nil にしない（前の画像を保持して "読み込み中" 表示を防ぐ）
        currentPlayer?.pause()
        currentPlayer = nil
        updateLocation()
        guard let asset = currentAsset else {
            currentImage = nil
            currentIsVideo = false
            currentIsFavorite = false
            return
        }
        let requestedAssetID = asset.localIdentifier
        currentIsVideo = (asset.mediaType == .video)
        currentIsFavorite = asset.isFavorite

        // 静止画（写真本体 or 動画のポスターフレーム）
        if let id = imageRequestID { cachingManager.cancelImageRequest(id) }
        // 先読み済みのキャッシュに同条件のリクエストが当たれば即座に返ってくる
        imageRequestID = cachingManager.requestImage(
            for: asset, targetSize: cacheTargetSize, contentMode: .aspectFit, options: cacheImageOptions
        ) { img, _ in
            guard let img = img else { return }
            Task { @MainActor in
                if self.currentAsset?.localIdentifier == requestedAssetID {
                    self.currentImage = img
                }
            }
        }

        // 動画なら再生用プレイヤーを用意
        if asset.mediaType == .video {
            let vopts = PHVideoRequestOptions()
            vopts.isNetworkAccessAllowed = true
            vopts.deliveryMode = .automatic
            imageManager.requestPlayerItem(forVideo: asset, options: vopts) { item, _ in
                guard let item else { return }
                Task { @MainActor in
                    if self.currentAsset?.localIdentifier == requestedAssetID {
                        self.currentPlayer = AVPlayer(playerItem: item)
                    }
                }
            }
        }

        // 前後の写真を裏で先読み
        updateImageCache()
    }

    /// 現在表示中のインデックス前後 ±cacheRange 枚を裏でキャッシュする
    private func updateImageCache() {
        guard !assets.isEmpty else {
            if !cachedAssetIDs.isEmpty {
                cachingManager.stopCachingImagesForAllAssets()
                cachedAssetIDs.removeAll()
            }
            return
        }
        let lo = max(0, currentIndex - cacheRange)
        let hi = min(assets.count - 1, currentIndex + cacheRange)
        guard lo <= hi else { return }
        let newAssets = Array(assets[lo...hi])
        let newIDs = Set(newAssets.map { $0.localIdentifier })

        // 新しく追加すべきもの
        let toAdd = newAssets.filter { !cachedAssetIDs.contains($0.localIdentifier) }
        // 範囲外になったもの
        let toRemoveIDs = cachedAssetIDs.subtracting(newIDs)
        let toRemove = assets.filter { toRemoveIDs.contains($0.localIdentifier) }

        if !toRemove.isEmpty {
            cachingManager.stopCachingImages(for: toRemove,
                targetSize: cacheTargetSize, contentMode: .aspectFit, options: cacheImageOptions)
        }
        if !toAdd.isEmpty {
            cachingManager.startCachingImages(for: toAdd,
                targetSize: cacheTargetSize, contentMode: .aspectFit, options: cacheImageOptions)
        }
        cachedAssetIDs = newIDs
    }

    /// ソースアルバム切替時など、キャッシュを全クリアする
    func resetImageCache() {
        cachingManager.stopCachingImagesForAllAssets()
        cachedAssetIDs.removeAll()
    }

    /// 現在の写真の撮影場所を更新（座標→地名を逆ジオコーディング）
    func updateLocation() {
        geocoder.cancelGeocode()
        locationToken += 1
        let token = locationToken
        guard let loc = currentAsset?.location else {
            currentLocationString = "撮影場所 なし"
            return
        }
        let coord = String(format: "%.4f, %.4f", loc.coordinate.latitude, loc.coordinate.longitude)
        currentLocationString = "\(coord)（地名を検索中…）"
        geocoder.reverseGeocodeLocation(loc) { placemarks, _ in
            Task { @MainActor in
                guard token == self.locationToken else { return } // 古い結果は破棄
                if let p = placemarks?.first {
                    self.currentLocationString = self.formatPlacemark(p, fallback: coord)
                } else {
                    self.currentLocationString = coord
                }
            }
        }
    }

    private func formatPlacemark(_ p: CLPlacemark, fallback: String) -> String {
        var parts: [String] = []
        if let country = p.country { parts.append(country) }
        if let admin = p.administrativeArea { parts.append(admin) }   // 都道府県
        if let locality = p.locality { parts.append(locality) }       // 市区町村
        if let sub = p.subLocality { parts.append(sub) }              // 地区
        var s = parts.joined(separator: " ")
        if let poi = p.areasOfInterest?.first {
            s = s.isEmpty ? poi : "\(s)（\(poi)）"
        }
        return s.isEmpty ? fallback : s
    }

    // MARK: Navigation

    func skip() {
        guard !assets.isEmpty else { return }
        currentIndex = min(currentIndex + 1, assets.count - 1)
        loadCurrentImage()
    }

    func back() {
        guard !assets.isEmpty else { return }
        currentIndex = max(currentIndex - 1, 0)
        loadCurrentImage()
    }

    // MARK: Move operations

    /// 既存アルバムへ移動（選択があればまとめて、無ければ現在の1枚）
    func move(to album: PHAssetCollection) {
        let targets = assetsToActOn()
        guard !targets.isEmpty, let source = effectiveSourceAlbum else { return }
        let title = album.localizedTitle ?? "(無題)"
        let albumID = album.localIdentifier
        let ids = targets.map { $0.localIdentifier }
        let removeFromSrc = shouldRemoveFromSource
        let sourceID = source.localIdentifier
        let sourceTitle = sourceAlbumTitle
        isWorking = true
        PHPhotoLibrary.shared().performChanges {
            if let addReq = PHAssetCollectionChangeRequest(for: album) {
                addReq.addAssets(targets as NSArray)
            }
            if removeFromSrc, let rmReq = PHAssetCollectionChangeRequest(for: source) {
                rmReq.removeAssets(targets as NSArray)
            }
        } completionHandler: { success, error in
            Task { @MainActor in
                self.isWorking = false
                if success {
                    self.movedCount += targets.count
                    self.undoStack.append(UndoEntry(
                        assetIDs: ids, albumID: albumID, albumTitle: title, wasNewlyCreated: false,
                        sourceAlbumID: sourceID, sourceAlbumTitle: sourceTitle,
                        wasRemovedFromSource: removeFromSrc))
                    self.redoStack.removeAll()
                    self.finishMove(ids, didRemove: removeFromSrc)
                    self.statusMessage = self.moveMessage(count: targets.count, title: title, created: false,
                                                          removed: removeFromSrc)
                } else {
                    self.statusMessage = "失敗: \(error?.localizedDescription ?? "不明なエラー")"
                }
            }
        }
    }

    /// 新規アルバムを作って移動（選択があればまとめて、無ければ現在の1枚）
    func createAlbumAndMove(title rawTitle: String) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = assetsToActOn()
        guard !title.isEmpty, !targets.isEmpty, let source = effectiveSourceAlbum else { return }
        let ids = targets.map { $0.localIdentifier }
        let removeFromSrc = shouldRemoveFromSource
        let sourceID = source.localIdentifier
        let sourceTitle = sourceAlbumTitle
        var placeholder: PHObjectPlaceholder?
        isWorking = true
        PHPhotoLibrary.shared().performChanges {
            let create = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            create.addAssets(targets as NSArray)
            placeholder = create.placeholderForCreatedAssetCollection
            if removeFromSrc, let rmReq = PHAssetCollectionChangeRequest(for: source) {
                rmReq.removeAssets(targets as NSArray)
            }
        } completionHandler: { success, error in
            Task { @MainActor in
                self.isWorking = false
                if success {
                    self.movedCount += targets.count
                    if let albumID = placeholder?.localIdentifier {
                        self.undoStack.append(UndoEntry(
                            assetIDs: ids, albumID: albumID, albumTitle: title, wasNewlyCreated: true,
                            sourceAlbumID: sourceID, sourceAlbumTitle: sourceTitle,
                            wasRemovedFromSource: removeFromSrc))
                    }
                    self.redoStack.removeAll()
                    self.finishMove(ids, didRemove: removeFromSrc)
                    self.loadTargetAlbums()
                    self.statusMessage = self.moveMessage(count: targets.count, title: title, created: true,
                                                          removed: removeFromSrc)
                } else {
                    self.statusMessage = "失敗: \(error?.localizedDescription ?? "不明なエラー")"
                }
            }
        }
    }

    private func moveMessage(count: Int, title: String, created: Bool, removed: Bool) -> String {
        let prefix = created ? "新規アルバム「\(title)」を作成して" : "「\(title)」へ"
        let verb = removed ? "移動しました" : "コピーしました"
        let body = count == 1 ? verb : "\(count) 枚を" + verb
        return "\(prefix)\(body)（累計 \(movedCount) 枚）"
    }

    private func finishMove(_ ids: [String], didRemove: Bool = true) {
        selectedIDs.subtract(ids)
        // 元から取り除いた場合は一覧から消す。残した場合（コピー）も次の写真へ進みたいので外す
        // （ソースアルバムをリロードすれば戻ってくる。再度仕分けたければソース切替）
        removeAssets(ids)
        if didRemove { markMoved(ids) }   // ★ 自動取り込みで「復活」させない（remove したときのみ）
    }

    // MARK: お気に入り（Photos の ❤️ フラグ）

    /// 選択（無ければ現在の1枚）のお気に入り状態を切り替える。
    /// 選択がある場合、最初の写真の現在の状態を反転 → 全部その状態に揃える。
    func toggleFavorite() {
        let targets = assetsToActOn()
        guard !targets.isEmpty else { return }
        // 全部が お気に入り なら解除、そうでなければ全部お気に入りに
        let allFav = targets.allSatisfy { $0.isFavorite }
        let newValue = !allFav
        let ids = targets.map { $0.localIdentifier }
        PHPhotoLibrary.shared().performChanges {
            for a in targets {
                let req = PHAssetChangeRequest(for: a)
                req.isFavorite = newValue
            }
        } completionHandler: { success, error in
            Task { @MainActor in
                if success {
                    // 表示更新（fetch し直して isFavorite を反映）
                    let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
                    fetch.enumerateObjects { a, _, _ in
                        if let idx = self.assets.firstIndex(where: { $0.localIdentifier == a.localIdentifier }) {
                            self.assets[idx] = a
                        }
                    }
                    if let cur = self.currentAsset { self.currentIsFavorite = cur.isFavorite }
                    let n = targets.count
                    let verb = newValue ? "お気に入りに追加" : "お気に入りから解除"
                    self.statusMessage = n == 1 ? "\(verb)しました。" : "\(n) 枚を\(verb)しました。"
                } else {
                    self.statusMessage = "お気に入り変更に失敗: \(error?.localizedDescription ?? "不明")"
                }
            }
        }
    }

    // MARK: アルバム名の変更

    func renameAlbum(_ album: PHAssetCollection, to rawName: String) {
        let newName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldName = album.localizedTitle ?? ""
        guard !newName.isEmpty, newName != oldName else { return }
        isWorking = true
        PHPhotoLibrary.shared().performChanges {
            if let req = PHAssetCollectionChangeRequest(for: album) {
                req.title = newName
            }
        } completionHandler: { success, error in
            Task { @MainActor in
                self.isWorking = false
                if success {
                    self.loadTargetAlbums()
                    self.statusMessage = "アルバム名を「\(oldName)」→「\(newName)」に変更しました。"
                } else {
                    self.statusMessage = "名前の変更に失敗: \(error?.localizedDescription ?? "不明なエラー")"
                }
            }
        }
    }

    // MARK: 「削除予定」アルバムへ移動 & 一括ゴミ箱送り

    /// 選択（無ければ現在の1枚）を「削除予定」アルバムへ移動する。
    /// 通常の move と同じく Cmd+Z で取り消し可能。アルバムが無ければ自動作成。
    func moveToPendingDelete() {
        let targets = assetsToActOn()
        guard !targets.isEmpty, let source = effectiveSourceAlbum else { return }
        let ids = targets.map { $0.localIdentifier }
        let removeFromSrc = shouldRemoveFromSource
        let sourceID = source.localIdentifier
        let sourceTitle = sourceAlbumTitle

        if let pending = pendingDeleteAlbum {
            let title = pendingDeleteAlbumTitle
            let albumID = pending.localIdentifier
            isWorking = true
            PHPhotoLibrary.shared().performChanges {
                if let addReq = PHAssetCollectionChangeRequest(for: pending) {
                    addReq.addAssets(targets as NSArray)
                }
                if removeFromSrc, let rmReq = PHAssetCollectionChangeRequest(for: source) {
                    rmReq.removeAssets(targets as NSArray)
                }
            } completionHandler: { success, error in
                Task { @MainActor in
                    self.isWorking = false
                    if success {
                        self.movedCount += targets.count
                        self.undoStack.append(UndoEntry(
                            assetIDs: ids, albumID: albumID, albumTitle: title, wasNewlyCreated: false,
                            sourceAlbumID: sourceID, sourceAlbumTitle: sourceTitle,
                            wasRemovedFromSource: removeFromSrc))
                        self.redoStack.removeAll()
                        self.finishMove(ids, didRemove: removeFromSrc)
                        self.loadPendingDeleteAlbum()
                        self.statusMessage = ids.count == 1
                            ? "「\(title)」へ移動しました（あとでまとめてゴミ箱へ送れます）"
                            : "\(ids.count) 枚を「\(title)」へ移動しました"
                    } else {
                        self.statusMessage = "失敗: \(error?.localizedDescription ?? "不明なエラー")"
                    }
                }
            }
        } else {
            let title = pendingDeleteAlbumTitle
            var placeholder: PHObjectPlaceholder?
            isWorking = true
            PHPhotoLibrary.shared().performChanges {
                let create = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                create.addAssets(targets as NSArray)
                placeholder = create.placeholderForCreatedAssetCollection
                if removeFromSrc, let rmReq = PHAssetCollectionChangeRequest(for: source) {
                    rmReq.removeAssets(targets as NSArray)
                }
            } completionHandler: { success, error in
                Task { @MainActor in
                    self.isWorking = false
                    if success {
                        self.movedCount += targets.count
                        if let albumID = placeholder?.localIdentifier {
                            self.undoStack.append(UndoEntry(
                                assetIDs: ids, albumID: albumID, albumTitle: title, wasNewlyCreated: true,
                                sourceAlbumID: sourceID, sourceAlbumTitle: sourceTitle,
                                wasRemovedFromSource: removeFromSrc))
                        }
                        self.redoStack.removeAll()
                        self.finishMove(ids, didRemove: removeFromSrc)
                        self.loadPendingDeleteAlbum()
                        self.loadTargetAlbums()
                        self.statusMessage = "「\(title)」アルバムを作って移動しました（あとでまとめてゴミ箱へ送れます）"
                    } else {
                        self.statusMessage = "失敗: \(error?.localizedDescription ?? "不明なエラー")"
                    }
                }
            }
        }
    }

    /// 「削除予定」アルバムの中身を全部 Photos のゴミ箱（最近削除した項目）へ送る。
    /// macOS では実行時にシステムの確認ダイアログが出る。アプリ内Undof対象外
    /// （復元は Photos アプリの「最近削除した項目」から行う）。
    func emptyPendingDelete() {
        guard let pending = pendingDeleteAlbum else { return }
        let res = PHAsset.fetchAssets(in: pending, options: nil)
        var assets: [PHAsset] = []
        res.enumerateObjects { a, _, _ in assets.append(a) }
        guard !assets.isEmpty else {
            statusMessage = "「\(pendingDeleteAlbumTitle)」は空です。"
            return
        }
        let count = assets.count
        isWorking = true
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        } completionHandler: { success, error in
            Task { @MainActor in
                self.isWorking = false
                if success {
                    self.loadPendingDeleteAlbum()
                    self.statusMessage = "\(count) 枚を Photos のゴミ箱（最近削除した項目）へ移動しました。"
                } else {
                    self.statusMessage = "削除はキャンセルされました。"
                }
            }
        }
    }

    // MARK: Delete (Photos のゴミ箱へ直接：上級者向け・通常は moveToPendingDelete を使う)

    /// 選択（無ければ現在の1枚）を Photos の「最近削除した項目」へ直接移動する。
    /// macOS では実行時にシステムの確認ダイアログが出る。アプリ内Undoの対象外
    /// （復元は Photos アプリの「最近削除した項目」から行う）。
    func deleteSelectedOrCurrent() {
        let targets = assetsToActOn()
        guard !targets.isEmpty else { return }
        let ids = targets.map { $0.localIdentifier }
        isWorking = true
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(targets as NSArray)
        } completionHandler: { success, error in
            Task { @MainActor in
                self.isWorking = false
                if success {
                    self.selectedIDs.subtract(ids)
                    self.removeAssets(ids)
                    self.markMoved(ids)   // 削除中の写真も自動取り込み対象から除外
                    self.statusMessage = ids.count == 1
                        ? "写真を Photos のゴミ箱（最近削除した項目）へ移動しました。"
                        : "\(ids.count) 枚を Photos のゴミ箱（最近削除した項目）へ移動しました。"
                } else {
                    self.statusMessage = "削除はキャンセルされました。"
                }
            }
        }
    }

    // MARK: Undo

    func undoLast() {
        guard let entry = undoStack.last else { return }
        let assetRes = PHAsset.fetchAssets(withLocalIdentifiers: entry.assetIDs, options: nil)
        let colRes = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [entry.albumID], options: nil)
        var movedAssets: [PHAsset] = []
        assetRes.enumerateObjects { a, _, _ in movedAssets.append(a) }
        guard let album = colRes.firstObject, !movedAssets.isEmpty else {
            statusMessage = "取り消し対象が見つかりませんでした。"
            undoStack.removeLast()
            return
        }
        // 元アルバム（あれば）を fetch。無ければ未整理にフォールバック
        let sourceCol: PHAssetCollection? = {
            if let sid = entry.sourceAlbumID {
                let r = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [sid], options: nil)
                return r.firstObject ?? unsortedAlbum
            }
            return unsortedAlbum
        }()
        isWorking = true
        PHPhotoLibrary.shared().performChanges {
            // 移動先から取り除く
            if let rmReq = PHAssetCollectionChangeRequest(for: album) {
                rmReq.removeAssets(movedAssets as NSArray)
            }
            // 元から削除していたなら、元へ戻す
            if entry.wasRemovedFromSource, let src = sourceCol,
               let addReq = PHAssetCollectionChangeRequest(for: src) {
                addReq.addAssets(movedAssets as NSArray)
            }
        } completionHandler: { success, error in
            Task { @MainActor in
                self.isWorking = false
                if success {
                    self.undoStack.removeLast()
                    self.redoStack.append(entry)
                    self.movedCount = max(0, self.movedCount - movedAssets.count)
                    for id in entry.assetIDs { self.recentlyMovedIDs.removeValue(forKey: id) }
                    if entry.wasNewlyCreated {
                        self.deleteAlbumIfEmpty(albumID: entry.albumID)
                    }
                    self.loadAssets(preservePosition: true)
                    let n = movedAssets.count
                    let toLabel = entry.wasRemovedFromSource ? "→「\(entry.sourceAlbumTitle)」に戻し" : "から取り除き"
                    self.statusMessage = "取り消しました：\(n == 1 ? "" : "\(n) 枚を ")「\(entry.albumTitle)」\(toLabel)ました。"
                } else {
                    self.statusMessage = "取り消し失敗: \(error?.localizedDescription ?? "不明なエラー")"
                }
            }
        }
    }

    /// 取り消した操作を再実行（Cmd+Shift+Z）
    func redoLast() {
        guard let entry = redoStack.last else { return }
        let assetRes = PHAsset.fetchAssets(withLocalIdentifiers: entry.assetIDs, options: nil)
        var movedAssets: [PHAsset] = []
        assetRes.enumerateObjects { a, _, _ in movedAssets.append(a) }
        guard !movedAssets.isEmpty else {
            statusMessage = "やり直し対象が見つかりませんでした。"
            redoStack.removeLast()
            return
        }
        // 元（ソース）アルバムを fetch
        let sourceCol: PHAssetCollection? = {
            if let sid = entry.sourceAlbumID {
                let r = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [sid], options: nil)
                return r.firstObject ?? unsortedAlbum
            }
            return unsortedAlbum
        }()
        isWorking = true
        let title = entry.albumTitle
        let originalEntry = entry

        if entry.wasNewlyCreated {
            var placeholder: PHObjectPlaceholder?
            PHPhotoLibrary.shared().performChanges {
                let create = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                create.addAssets(movedAssets as NSArray)
                placeholder = create.placeholderForCreatedAssetCollection
                if originalEntry.wasRemovedFromSource, let src = sourceCol,
                   let rmReq = PHAssetCollectionChangeRequest(for: src) {
                    rmReq.removeAssets(movedAssets as NSArray)
                }
            } completionHandler: { success, error in
                Task { @MainActor in
                    self.isWorking = false
                    if success, let newAlbumID = placeholder?.localIdentifier {
                        self.redoStack.removeLast()
                        let newEntry = UndoEntry(
                            assetIDs: originalEntry.assetIDs,
                            albumID: newAlbumID,
                            albumTitle: title,
                            wasNewlyCreated: true,
                            sourceAlbumID: originalEntry.sourceAlbumID,
                            sourceAlbumTitle: originalEntry.sourceAlbumTitle,
                            wasRemovedFromSource: originalEntry.wasRemovedFromSource)
                        self.undoStack.append(newEntry)
                        self.movedCount += movedAssets.count
                        self.finishMove(originalEntry.assetIDs, didRemove: originalEntry.wasRemovedFromSource)
                        self.loadTargetAlbums()
                        let n = movedAssets.count
                        self.statusMessage = "元に戻しました：\(n == 1 ? "" : "\(n) 枚を ")「\(title)」へ。"
                    } else {
                        self.statusMessage = "やり直し失敗: \(error?.localizedDescription ?? "不明なエラー")"
                    }
                }
            }
        } else {
            let colRes = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [entry.albumID], options: nil)
            guard let album = colRes.firstObject else {
                isWorking = false
                statusMessage = "やり直し先アルバム「\(title)」が見つかりませんでした。"
                redoStack.removeLast()
                return
            }
            PHPhotoLibrary.shared().performChanges {
                if let addReq = PHAssetCollectionChangeRequest(for: album) {
                    addReq.addAssets(movedAssets as NSArray)
                }
                if originalEntry.wasRemovedFromSource, let src = sourceCol,
                   let rmReq = PHAssetCollectionChangeRequest(for: src) {
                    rmReq.removeAssets(movedAssets as NSArray)
                }
            } completionHandler: { success, error in
                Task { @MainActor in
                    self.isWorking = false
                    if success {
                        self.redoStack.removeLast()
                        self.undoStack.append(originalEntry)
                        self.movedCount += movedAssets.count
                        self.finishMove(originalEntry.assetIDs, didRemove: originalEntry.wasRemovedFromSource)
                        let n = movedAssets.count
                        self.statusMessage = "元に戻しました：\(n == 1 ? "" : "\(n) 枚を ")「\(title)」へ。"
                    } else {
                        self.statusMessage = "やり直し失敗: \(error?.localizedDescription ?? "不明なエラー")"
                    }
                }
            }
        }
    }

    /// 新規作成したアルバムを取り消し、空になった場合のみ削除する
    private func deleteAlbumIfEmpty(albumID: String) {
        let colRes = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil)
        guard let album = colRes.firstObject else { return }
        let count = PHAsset.fetchAssets(in: album, options: nil).count
        guard count == 0 else { return }
        PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray)
        } completionHandler: { _, _ in
            Task { @MainActor in self.loadTargetAlbums() }
        }
    }

    /// 指定IDの写真を一覧から取り除き、表示位置をできるだけ維持する
    private func removeAssets(_ ids: [String]) {
        let idSet = Set(ids)
        let curID = currentAsset?.localIdentifier
        assets.removeAll { idSet.contains($0.localIdentifier) }
        if let curID, !idSet.contains(curID),
           let newIdx = assets.firstIndex(where: { $0.localIdentifier == curID }) {
            currentIndex = newIdx           // 現在の写真が残っていれば追従
        } else {
            currentIndex = min(currentIndex, max(assets.count - 1, 0)) // 消えたら同じ位置＝次の写真
        }
        loadCurrentImage()
    }
}

// MARK: - Root View

struct ContentView: View {
    @StateObject private var model = TriageModel()

    var body: some View {
        Group {
            switch model.authStatus {
            case .authorized, .limited:
                if model.unsortedAlbum == nil {
                    MissingAlbumView(model: model)
                } else {
                    // assets が空でも TriageView を見せる：
                    // ソース切替・削除予定送り・取り消しなど操作系を引き続き使えるようにするため
                    TriageView(model: model)
                }
            case .denied, .restricted:
                DeniedView()
            default:
                RequestView(model: model)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .onAppear { model.checkAuth() }
    }
}

// MARK: - Triage View

struct TriageView: View {
    @ObservedObject var model: TriageModel
    @State private var filter = ""
    @State private var newAlbumName = ""
    // アルバム名変更
    @State private var renameTarget: PHAssetCollection?
    @State private var renameText: String = ""
    @State private var showRename = false
    // 「削除予定」をまとめてゴミ箱へ送る確認
    @State private var showEmptyDeleteConfirm = false
    // ドラッグ選択用（開始セル〜現在セルの範囲選択。戻すと範囲外は元に戻る）
    @State private var cellFrames: [String: CGRect] = [:]   // ビューポート基準のセル位置
    @State private var dragPaintSelect: Bool? = nil          // nil=未確定 / true=選択 / false=解除
    @State private var dragAnchorIndex: Int? = nil           // ドラッグ開始セルの index
    @State private var dragModified: Set<Int> = []           // 直前ステップで範囲に含めた index
    @State private var dragOriginalSelected: Set<String> = [] // ドラッグ開始時点の選択状態
    @State private var dragLastHit: String? = nil
    // 端での連続自動スクロール用
    @State private var scrollPos = ScrollPosition(edge: .leading)
    @State private var viewportWidth: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var contentOffsetX: CGFloat = 0
    @State private var targetOffsetX: CGFloat = 0
    @State private var autoScrollDir: Int = 0              // -1=左 / 0=なし / +1=右
    @State private var autoScrollSpeed: CGFloat = 0        // pt/秒
    @State private var autoScrollTask: Task<Void, Never>? = nil
    @State private var lastPointer: CGPoint = .zero

    private var filteredAlbums: [PHAssetCollection] {
        if filter.isEmpty { return model.albums }
        return model.albums.filter {
            ($0.localizedTitle ?? "").localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
        HStack(spacing: 0) {
            // 左：写真ビューア
            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .foregroundStyle(.secondary)
                        Text(model.currentDateString)
                            .font(.headline.monospacedDigit())
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(.secondary)
                        Text(model.currentLocationString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    if model.assets.isEmpty {
                        // ソースに写真がない時：完了メッセージ＋ソース切替ヒント
                        VStack(spacing: 14) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 64))
                                .foregroundStyle(.green)
                            Text("「\(model.sourceAlbumTitle)」に写真はありません 🎉")
                                .font(.title2.bold())
                            if model.movedCount > 0 {
                                Text("このセッションで \(model.movedCount) 枚を仕分けしました。")
                                    .foregroundStyle(.secondary)
                            }
                            Text("右パネルの「仕分け元」から別のアルバムに切り替えて、続けて整理できます。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                            if model.pendingDeleteCount > 0 {
                                Button(role: .destructive) {
                                    showEmptyDeleteConfirm = true
                                } label: {
                                    Label("「\(model.pendingDeleteAlbumTitle)」の \(model.pendingDeleteCount) 枚をゴミ箱へ送る",
                                          systemImage: "trash.fill")
                                }
                                .tint(.red)
                                .controlSize(.large)
                                .disabled(model.isWorking)
                                .padding(.top, 4)
                            }
                        }
                        .padding(40)
                    } else if model.currentIsVideo {
                        // 動画：再生プレイヤー（用意中はポスター＋スピナー）
                        if let player = model.currentPlayer {
                            PlayerView(player: player)
                                .padding(16)
                        } else if let img = model.currentImage {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .padding(16)
                                .overlay(ProgressView())
                        } else {
                            ProgressView("動画を準備中…")
                        }
                    } else if let img = model.currentImage {
                        // 写真：ピンチでズーム＋二本指スワイプで移動（NSScrollView）
                        ZoomableImageView(image: img)
                            .padding(16)
                    } else {
                        ProgressView("読み込み中…")
                    }

                    if !model.currentIsVideo && !model.assets.isEmpty {
                        Text("ピンチで拡大・二本指で移動・ダブルクリックで戻す")
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.45), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                HStack {
                    Button("← 戻る") { model.back() }
                        .disabled(model.currentIndex == 0)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Spacer()
                    Text("\(model.currentIndex + 1) / \(model.assets.count)")
                        .font(.headline.monospacedDigit())

                    Button {
                        model.toggleFavorite()
                    } label: {
                        Label(
                            model.selectedCount > 0
                                ? "選択した \(model.selectedCount) 枚をお気に入り"
                                : (model.currentIsFavorite ? "お気に入り解除" : "お気に入り"),
                            systemImage: model.currentIsFavorite ? "heart.fill" : "heart"
                        )
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(model.currentIsFavorite ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isWorking || model.assets.isEmpty)
                    .keyboardShortcut(".", modifiers: [])
                    .help("お気に入りを切り替える（. キー）")

                    Spacer()
                    Button("スキップ →") { model.skip() }
                        .disabled(model.currentIndex >= model.assets.count - 1)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

                HStack {
                    Button(role: .destructive) {
                        model.moveToPendingDelete()
                    } label: {
                        Label(model.selectedCount > 0
                              ? "選択した \(model.selectedCount) 枚を「削除予定」へ"
                              : "この写真を「削除予定」へ",
                              systemImage: "trash")
                    }
                    .tint(.orange)
                    .disabled(model.isWorking || model.assets.isEmpty)
                    .help("「削除予定」アルバムへ移動します（あとでまとめてゴミ箱へ送れます。取り消しも可能）")

                    Spacer()

                    if model.pendingDeleteCount > 0 {
                        Button {
                            showEmptyDeleteConfirm = true
                        } label: {
                            Label("削除予定 \(model.pendingDeleteCount) 枚 をゴミ箱へ",
                                  systemImage: "trash.fill")
                        }
                        .tint(.red)
                        .disabled(model.isWorking)
                        .help("「削除予定」アルバムの中身をすべて Photos のゴミ箱（最近削除した項目）へ送ります")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 4)
            }

            Divider()

            // 右：移動先アルバム
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("移動先アルバムを選択")
                        .font(.title3.bold())
                    Spacer()
                    Button {
                        model.undoLast()
                    } label: {
                        Label("取り消し", systemImage: "arrow.uturn.backward")
                    }
                    .help(model.lastUndoTitle.map { "「\($0)」への移動を取り消す" } ?? "取り消す操作はありません")
                    .disabled(!model.canUndo || model.isWorking)
                    .keyboardShortcut("z", modifiers: .command)

                    Button {
                        model.redoLast()
                    } label: {
                        Label("元に戻す", systemImage: "arrow.uturn.forward")
                    }
                    .help(model.lastRedoTitle.map { "取り消した「\($0)」への移動をやり直す" } ?? "やり直す操作はありません")
                    .disabled(!model.canRedo || model.isWorking)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                }

                sourcePicker

                selectionBanner

                TextField("アルバムを絞り込み", text: $filter)
                    .textFieldStyle(.roundedBorder)

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(filteredAlbums, id: \.localIdentifier) { album in
                            HStack(spacing: 2) {
                                Button {
                                    model.move(to: album)
                                } label: {
                                    HStack {
                                        Image(systemName: "rectangle.stack")
                                            .foregroundStyle(.secondary)
                                        Text(album.localizedTitle ?? "(無題)")
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 7)
                                    .padding(.leading, 9)
                                }
                                .buttonStyle(.plain)

                                Menu {
                                    Button("名前を変更…") { startRename(album) }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .padding(.trailing, 8)
                            }
                            .background(Color.gray.opacity(0.12))
                            .cornerRadius(7)
                            .contextMenu {
                                Button("名前を変更…") { startRename(album) }
                            }
                        }
                        if filteredAlbums.isEmpty {
                            Text("該当アルバムなし")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                    }
                }

                Divider()

                Text("新規アルバムを作って移動")
                    .font(.subheadline.bold())
                HStack {
                    TextField("新しいアルバム名", text: $newAlbumName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { createNew() }
                    Button("作成") { createNew() }
                        .disabled(newAlbumName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
                if !model.statusMessage.isEmpty {
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(width: 340)
            .disabled(model.isWorking)
        }

        Divider()
        filmstrip
        }
        .alert("アルバム名を変更", isPresented: $showRename) {
            TextField("新しいアルバム名", text: $renameText)
            Button("変更") { commitRename() }
            Button("キャンセル", role: .cancel) { renameTarget = nil }
        } message: {
            Text("「\(renameTarget?.localizedTitle ?? "")」の新しい名前を入力してください。")
        }
        .alert("「削除予定」をゴミ箱へ送ります", isPresented: $showEmptyDeleteConfirm) {
            Button("ゴミ箱へ送る", role: .destructive) { model.emptyPendingDelete() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("「\(model.pendingDeleteAlbumTitle)」アルバムの \(model.pendingDeleteCount) 枚を Photos のゴミ箱（最近削除した項目）へ移動します。30日間は復元可能です。")
        }
    }

    // ソースアルバム選択
    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("仕分け元:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Menu {
                    Button {
                        model.setSourceAlbum(nil)
                    } label: {
                        Label("未整理（既定）", systemImage: model.isSourceUnsorted ? "checkmark" : "tray")
                    }
                    let others = model.availableSourceAlbums()
                    if !others.isEmpty {
                        Divider()
                        ForEach(others, id: \.localIdentifier) { album in
                            Button {
                                model.setSourceAlbum(album)
                            } label: {
                                let isCur = album.localIdentifier == model.sourceAlbum?.localIdentifier
                                Label(album.localizedTitle ?? "(無題)",
                                      systemImage: isCur ? "checkmark" : "rectangle.stack")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.isSourceUnsorted ? "tray.fill" : "rectangle.stack.fill")
                        Text(model.sourceAlbumTitle).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if !model.isSourceUnsorted {
                Toggle(isOn: Binding(
                    get: { model.removeFromSource },
                    set: { model.removeFromSource = $0 }
                )) {
                    Text("仕分け後は元のアルバム「\(model.sourceAlbumTitle)」から取り除く")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(6)
    }

    // 選択状態の案内バナー
    private var selectionBanner: some View {
        Group {
            if model.selectedCount > 0 {
                Label("選択中の \(model.selectedCount) 枚をまとめて移動します",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.tint)
            } else {
                Text("現在の1枚を移動します（下の一覧で複数選択も可）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 下部フィルムストリップ（未整理の全写真一覧・複数選択可）
    private var filmstrip: some View {
        VStack(spacing: 4) {
            HStack {
                Text("「\(model.sourceAlbumTitle)」の写真（\(model.assets.count) 枚）")
                    .font(.caption.bold())
                    .lineLimit(1)
                Button {
                    model.reloadAll()
                } label: {
                    if model.isReloading {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text("更新中…")
                        }
                    } else {
                        Label("更新", systemImage: "arrow.clockwise")
                    }
                }
                .controlSize(.small)
                .disabled(model.isReloading)
                .help("Photos の最新の状態を読み直します（⌘R）")
                .keyboardShortcut("r", modifiers: .command)
                if model.isSourceUnsorted {
                    Button {
                        model.importUnclassified()
                    } label: {
                        if model.isImporting {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small).scaleEffect(0.7)
                                Text("取り込み中…")
                            }
                        } else {
                            Label("新しい写真を取り込む", systemImage: "arrow.down.circle")
                        }
                    }
                    .controlSize(.small)
                    .disabled(model.isImporting)
                    .help("どのアルバムにも入っていない写真を「未整理」へ追加します")
                }
                Spacer()
                if model.selectedCount > 0 {
                    Text("\(model.selectedCount) 枚選択中")
                        .font(.caption)
                        .foregroundStyle(.tint)
                    Button("選択解除") { model.clearSelection() }
                        .controlSize(.small)
                }
                Button("すべて選択") { model.selectAll() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            Text("1回クリックでプレビュー／2回目で選択／ドラッグでまとめて選択")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)

            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 6) {
                    ForEach(model.assets, id: \.localIdentifier) { asset in
                        FilmstripCell(
                            asset: asset,
                            isCurrent: asset.localIdentifier == model.currentAsset?.localIdentifier,
                            isSelected: model.isSelected(asset),
                            onTap: {
                                // 1クリック目：プレビュー表示のみ
                                // 2クリック目（既にプレビュー中）：選択トグル
                                if model.currentAsset?.localIdentifier == asset.localIdentifier {
                                    model.toggleSelection(asset)
                                } else {
                                    model.setCurrent(asset)
                                }
                            }
                        )
                        .id(asset.localIdentifier)   // scrollPosition(id:) で個別スクロール対象
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: CellFramesKey.self,
                                    value: [asset.localIdentifier: geo.frame(in: .named("viewport"))]
                                )
                            }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .gesture(selectionDrag)
            }
            .coordinateSpace(name: "viewport")
            .scrollPosition($scrollPos)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                ScrollMetrics(offsetX: geo.contentOffset.x,
                              contentWidth: geo.contentSize.width,
                              viewportWidth: geo.containerSize.width)
            } action: { _, m in
                contentOffsetX = m.offsetX
                contentWidth = m.contentWidth
                viewportWidth = m.viewportWidth
            }
            .onPreferenceChange(CellFramesKey.self) { cellFrames = $0 }
            .onChange(of: model.currentAsset?.localIdentifier) { _, newID in
                guard let newID, viewportWidth > 0 else { return }
                // ビューポート外（または端ギリギリ）にいる時だけ自動スクロール
                let margin: CGFloat = 12
                if let f = cellFrames[newID] {
                    let isOffLeft  = f.minX < margin
                    let isOffRight = f.maxX > viewportWidth - margin
                    if isOffLeft || isOffRight {
                        withAnimation(.easeOut(duration: 0.2)) {
                            scrollPos.scrollTo(id: newID, anchor: .center)
                        }
                    }
                } else {
                    // フレーム未取得（リサイクル外） → 何が何でも見せる
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrollPos.scrollTo(id: newID, anchor: .center)
                    }
                }
            }
        }
        .frame(height: 158)
        .background(Color(nsColor: .underPageBackgroundColor))
        .disabled(model.isWorking)
    }

    /// なぞった写真をまとめて選択／解除するドラッグジェスチャ（端で連続自動スクロール）
    private var selectionDrag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("viewport"))
            .onChanged { value in
                lastPointer = value.location
                paintSelection(at: value.location)
                updateAutoScroll(pointerX: value.location.x)
            }
            .onEnded { _ in
                stopAutoScroll()
                if let last = dragLastHit { model.setCurrentByID(last) } // なぞり終わりをプレビュー
                dragPaintSelect = nil
                dragAnchorIndex = nil
                dragModified.removeAll()
                dragOriginalSelected.removeAll()
                dragLastHit = nil
            }
    }

    /// 開始セル〜現在セルの範囲を塗り、行き過ぎて戻った分は元の状態へ復元する
    private func paintSelection(at loc: CGPoint) {
        guard let hitID = cellFrames.first(where: { $0.value.contains(loc) })?.key,
              let index = model.assets.firstIndex(where: { $0.localIdentifier == hitID })
        else { return }

        if dragAnchorIndex == nil {
            dragAnchorIndex = index
            dragOriginalSelected = model.selectedIDs               // 開始時の状態を記録
            dragPaintSelect = !dragOriginalSelected.contains(hitID) // 開始セルが未選択なら「選択」モード
            dragModified = []
        }
        guard let anchor = dragAnchorIndex, let paint = dragPaintSelect else { return }

        let lo = min(anchor, index), hi = max(anchor, index)
        let current = Set(lo...hi)
        let count = model.assets.count
        // 直前まで触れていた範囲 ∪ 今回の範囲 を見直す
        for i in dragModified.union(current) where i >= 0 && i < count {
            let id = model.assets[i].localIdentifier
            if current.contains(i) {
                model.setSelected(id, paint)                       // 範囲内は塗る
            } else {
                model.setSelected(id, dragOriginalSelected.contains(id)) // 範囲外は開始時へ復元
            }
        }
        dragModified = current
        dragLastHit = hitID
    }

    // MARK: 端での連続自動スクロール

    private func updateAutoScroll(pointerX: CGFloat) {
        let margin: CGFloat = 70
        let minSpeed: CGFloat = 180     // pt/秒
        let maxSpeed: CGFloat = 1600    // pt/秒
        var dir = 0
        var depth: CGFloat = 0
        if viewportWidth > 0 && pointerX > viewportWidth - margin {
            dir = 1
            depth = min(pointerX - (viewportWidth - margin), margin) / margin
        } else if pointerX < margin {
            dir = -1
            depth = min(margin - pointerX, margin) / margin
        }
        // 端に深く入るほど速く（イージング）
        autoScrollSpeed = minSpeed + (maxSpeed - minSpeed) * depth * depth
        if dir == 0 {
            stopAutoScroll()
        } else {
            startAutoScroll(dir)
        }
    }

    private func startAutoScroll(_ dir: Int) {
        if autoScrollDir == 0 {
            targetOffsetX = contentOffsetX   // 開始時に実スクロール位置へ同期
        }
        autoScrollDir = dir
        guard autoScrollTask == nil else { return }
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled && autoScrollDir != 0 {
                tickAutoScroll()
                try? await Task.sleep(nanoseconds: 16_000_000) // 約60fps
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollDir = 0
        autoScrollTask?.cancel()
        autoScrollTask = nil
    }

    /// 1フレーム分だけオフセットを動かす（連続スクロール）
    private func tickAutoScroll() {
        guard autoScrollDir != 0 else { return }
        let maxX = max(0, contentWidth - viewportWidth)
        let dt: CGFloat = 0.016
        let delta = CGFloat(autoScrollDir) * autoScrollSpeed * dt
        let newX = min(max(targetOffsetX + delta, 0), maxX)
        // 端に到達して動けないなら、塗りだけ続けて空回りを避ける
        if newX != targetOffsetX {
            targetOffsetX = newX
            scrollPos.scrollTo(x: targetOffsetX)
        }
        paintSelection(at: lastPointer)
    }

    private func createNew() {
        let name = newAlbumName
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.createAlbumAndMove(title: name)
        newAlbumName = ""
    }

    private func startRename(_ album: PHAssetCollection) {
        renameTarget = album
        renameText = album.localizedTitle ?? ""
        showRename = true
    }

    private func commitRename() {
        guard let album = renameTarget else { return }
        model.renameAlbum(album, to: renameText)
        renameTarget = nil
    }
}

// MARK: - 動画プレイヤー（AppKit の AVPlayerView を使用：安定）

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = true
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

// MARK: - 拡大できる写真ビュー（NSScrollView：二本指で移動・ピンチで拡大）

/// 倍率1のときは画像をビューポートにフィットさせ、拡大時のみパン可能にする
final class FitScrollView: NSScrollView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if magnification <= 1.001 {
            documentView?.frame = CGRect(origin: .zero, size: contentView.bounds.size)
        }
    }
}

struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FitScrollView {
        let scroll = FitScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 8
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.usesPredominantAxisScrolling = false   // 斜め移動を許可（軸ロック解除）
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .allowed
        scroll.wantsLayer = true

        let iv = NSImageView()
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignCenter
        iv.wantsLayer = true
        scroll.documentView = iv

        let dbl = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleClick(_:)))
        dbl.numberOfClicksRequired = 2
        scroll.addGestureRecognizer(dbl)

        context.coordinator.scroll = scroll
        return scroll
    }

    func updateNSView(_ scroll: FitScrollView, context: Context) {
        guard let iv = scroll.documentView as? NSImageView else { return }
        guard iv.image !== image else { return }
        // 暗黙アニメーション無効・最小処理だけ実行
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            if scroll.magnification != 1 {
                scroll.magnification = 1
            }
            iv.image = image
            // フレームが変わっていなければ再設定もしない（再レイアウトを回避）
            let target = scroll.contentView.bounds.size
            if iv.frame.size != target {
                iv.frame = CGRect(origin: .zero, size: target)
            }
        }
    }

    final class Coordinator: NSObject {
        weak var scroll: FitScrollView?

        @objc func handleDoubleClick(_ g: NSClickGestureRecognizer) {
            guard let scroll, let doc = scroll.documentView else { return }
            if scroll.magnification > 1.01 {
                scroll.animator().magnification = 1
            } else {
                let pt = g.location(in: doc)
                scroll.setMagnification(2.5, centeredAt: pt)
            }
        }
    }
}

// MARK: - Filmstrip components

/// 各サムネイルの位置を集約するための PreferenceKey（ドラッグ選択の当たり判定用）
struct CellFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// スクロール状態（自動スクロールの速度・上限計算用）
struct ScrollMetrics: Equatable {
    var offsetX: CGFloat
    var contentWidth: CGFloat
    var viewportWidth: CGFloat
}

/// サムネイル1枚（遅延読み込み・まず低解像度→高解像度に差し替え）
struct ThumbnailView: View {
    let asset: PHAsset
    private let side: CGFloat = 100
    @State private var image: NSImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.15)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear { startLoad() }
        .onDisappear { cancel() }
        .onChange(of: asset.localIdentifier) {
            image = nil
            startLoad()
        }
    }

    private func startLoad() {
        cancel()
        // Retina 解像度（×2 など）で正確にリサイズして鮮明に
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let dim = side * scale
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .opportunistic   // まず速報（低解像度）→ 自動で高解像度に更新
        opts.resizeMode = .exact             // 要求サイズへ正確にリサイズ
        let target = CGSize(width: dim, height: dim)
        requestID = PHImageManager.default().requestImage(
            for: asset, targetSize: target, contentMode: .aspectFill, options: opts
        ) { img, _ in
            guard let img else { return }
            DispatchQueue.main.async { self.image = img }
        }
    }

    private func cancel() {
        if let requestID {
            PHImageManager.default().cancelImageRequest(requestID)
            self.requestID = nil
        }
    }
}

/// フィルムストリップの1セル（写真のどこをタップしても選択＋プレビュー）
struct FilmstripCell: View {
    let asset: PHAsset
    let isCurrent: Bool
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        ThumbnailView(asset: asset)
            .frame(width: 100, height: 100)
            .clipped()
            .cornerRadius(7)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor.opacity(0.30) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isCurrent ? Color.accentColor : .clear, lineWidth: 3)
            )
            // 選択状態のインジケーター（操作は写真本体のタップで行う）
            .overlay(alignment: .topLeading) {
                ZStack {
                    Circle().fill(.black.opacity(0.4)).frame(width: 22, height: 22)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(isSelected ? Color.green : .white)
                }
                .padding(4)
            }
            // 動画バッジ
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }
            // お気に入りバッジ
            .overlay(alignment: .bottomLeading) {
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                        .shadow(color: .black.opacity(0.4), radius: 1)
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
    }
}

// MARK: - Auxiliary Views

struct RequestView: View {
    @ObservedObject var model: TriageModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("写真ライブラリへのアクセスが必要です")
                .font(.title2.bold())
            Text("「\(model.unsortedAlbumTitle)」アルバムの写真を読み込み、\n選んだアルバムへ移動するために使います。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("アクセスを許可する") { model.requestAccess() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

struct DeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("写真へのアクセスが拒否されています")
                .font(.title2.bold())
            Text("システム設定 → プライバシーとセキュリティ → 写真\nで、このアプリに「フルアクセス」を許可してください。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("システム設定を開く") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(40)
    }
}

struct MissingAlbumView: View {
    @ObservedObject var model: TriageModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("「\(model.unsortedAlbumTitle)」アルバムが見つかりません")
                .font(.title2.bold())
            Text("写真アプリで「\(model.unsortedAlbumTitle)」という名前の\n（手動作成の）アルバムがあるか確認してください。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("再読み込み") { model.loadEverything() }
        }
        .padding(40)
    }
}

struct DoneView: View {
    @ObservedObject var model: TriageModel
    @State private var showEmptyDeleteConfirm = false
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("「\(model.sourceAlbumTitle)」は空になりました 🎉")
                .font(.title2.bold())
            if model.movedCount > 0 {
                Text("このセッションで \(model.movedCount) 枚を仕分けしました。")
                    .foregroundStyle(.secondary)
            }
            if model.pendingDeleteCount > 0 {
                Button(role: .destructive) {
                    showEmptyDeleteConfirm = true
                } label: {
                    Label("「\(model.pendingDeleteAlbumTitle)」の \(model.pendingDeleteCount) 枚をゴミ箱へ送る",
                          systemImage: "trash.fill")
                }
                .tint(.red)
                .controlSize(.large)
                .disabled(model.isWorking)
            }
            Text("新しい写真が Photos に入ると自動で取り込まれます。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if model.canUndo {
                    Button {
                        model.undoLast()
                    } label: {
                        Label("直前を取り消し", systemImage: "arrow.uturn.backward")
                    }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(model.isWorking)
                }
                if model.canRedo {
                    Button {
                        model.redoLast()
                    } label: {
                        Label("元に戻す", systemImage: "arrow.uturn.forward")
                    }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(model.isWorking)
                }
                Button {
                    model.importUnclassified()
                } label: {
                    if model.isImporting {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text("取り込み中…")
                        }
                    } else {
                        Label("新しい写真を取り込む", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(model.isWorking || model.isImporting)
                Button("再読み込み") { model.loadEverything() }
            }
            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .alert("「\(model.pendingDeleteAlbumTitle)」をゴミ箱へ送ります", isPresented: $showEmptyDeleteConfirm) {
            Button("ゴミ箱へ送る", role: .destructive) { model.emptyPendingDelete() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("「\(model.pendingDeleteAlbumTitle)」アルバムの \(model.pendingDeleteCount) 枚を Photos のゴミ箱（最近削除した項目）へ移動します。30日間は復元可能です。")
        }
    }
}

// MARK: - App

@main
struct PhotoTriageApp: App {
    var body: some Scene {
        WindowGroup("Siftly") {
            ContentView()
        }
        .defaultSize(width: 1100, height: 720)
    }
}
