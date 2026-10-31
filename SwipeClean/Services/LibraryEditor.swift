import Photos

/// Изменения в медиатеке: удаление, избранное и альбомы.
///
/// PhotoKit выполняет блок изменений на своей очереди. Замыкание, созданное в коде главного актора,
/// Swift 6 считает изолированным и роняет приложение, когда его вызывают не с главного потока.
/// Поэтому все блоки здесь явно `@Sendable`: они не привязаны к актору и берут фото по идентификаторам.
enum LibraryEditor {
    /// Удаляет фото одним системным подтверждением. Уже удалённые снаружи фото пропускаются.
    /// Возвращает идентификаторы фото, которые были в медиатеке и удалены сейчас.
    @discardableResult
    static func deleteAssets(withIDs ids: [String]) async throws -> Set<String> {
        let existing = Set(ids).subtracting(LibraryFetcher.missingIDs(ids))
        guard !existing.isEmpty else { return [] }
        try await PHPhotoLibrary.shared().performChanges(deleteChanges(for: Array(existing)))
        return existing
    }

    static func deleteChanges(for ids: [String]) -> @Sendable () -> Void {
        {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            guard assets.count > 0 else { return }
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    static func setFavorite(_ asset: PHAsset, _ isFavorite: Bool) async throws {
        let id = asset.localIdentifier
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
            PHAssetChangeRequest(for: asset).isFavorite = isFavorite
        }
    }

    enum EditError: Error {
        /// Альбом удалили в приложении «Фото», а он остался закреплённым.
        case albumMissing
    }

    static func add(_ asset: PHAsset, toAlbum id: String) async throws {
        guard collection(id) != nil else { throw EditError.albumMissing }
        let assetID = asset.localIdentifier
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            guard let album = collection(id) else { return }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
            PHAssetCollectionChangeRequest(for: album)?.addAssets(assets)
        }
    }

    static func remove(_ asset: PHAsset, fromAlbum id: String) async throws {
        let assetID = asset.localIdentifier
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            guard let album = collection(id) else { return }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
            PHAssetCollectionChangeRequest(for: album)?.removeAssets(assets)
        }
    }

    /// Создаёт пользовательский альбом и возвращает его идентификатор.
    static func createAlbum(title: String) async throws -> String? {
        // Пишется только внутри блока, а читается после его завершения.
        nonisolated(unsafe) var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            placeholderID = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        return placeholderID
    }

    static func userAlbums() -> [AlbumInfo] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        var albums: [AlbumInfo] = []
        result.enumerateObjects { collection, _, _ in
            guard collection.canPerform(.addContent) else { return }
            albums.append(AlbumInfo(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? String(localized: "Без названия"),
                count: PHAsset.fetchAssets(in: collection, options: nil).count
            ))
        }
        return albums
    }

    /// Текущие названия альбомов по идентификаторам; удалённых альбомов в словаре нет.
    static func albumTitles(_ ids: [String]) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        var titles: [String: String] = [:]
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids, options: nil).enumerateObjects { collection, _, _ in
            titles[collection.localIdentifier] = collection.localizedTitle ?? String(localized: "Без названия")
        }
        return titles
    }

    private static func collection(_ id: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }
}

struct AlbumInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int
}
