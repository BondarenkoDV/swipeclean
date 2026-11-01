import Foundation
import Photos

/// Live Photo → обычное фото: от Live Photo остаётся только снимок, видео рядом с ним уходит.
///
/// Снимок не пережимается: новая запись медиатеки получает тот же файл (HEIC с HDR и EXIF как есть),
/// а у фото с правками — версию с правками. Дата, место, избранное, скрытость и альбомы переносятся.
/// Копии создаются и оригиналы удаляются в одном блоке изменений PhotoKit: это одна транзакция
/// и одно системное подтверждение. Если подтверждение отменить, медиатека не меняется совсем.
enum LivePhotoConverter {
    /// Live Photo в списке: сколько весит целиком и сколько из этого снимок.
    struct Candidate: Identifiable, Sendable {
        let asset: PHAsset
        let total: Int64
        let still: Int64
        var id: String { asset.localIdentifier }
        /// Сколько освободится: всё, кроме снимка (видео, а у изменённых ещё и исходники правок).
        var savings: Int64 { LivePhotoConverter.savings(total: total, still: still) }
    }

    /// Снимок, выгруженный во временный файл и готовый стать новой записью медиатеки.
    struct PreparedStill: Sendable {
        let originalID: String
        let url: URL
        let filename: String
        /// Сколько занимал оригинал со всеми ресурсами.
        let originalTotal: Int64
        let size: Int64
    }

    struct Outcome: Sendable, Equatable {
        /// Идентификатор оригинала → идентификатор нового фото.
        var replaced: [String: String] = [:]
        var saved: Int64 = 0
    }

    enum Failure: Error, Equatable {
        case noStill
        case writeFailed
    }

    /// Сколько Live Photos обрабатывается за одну транзакцию: столько снимков одновременно лежит во временной папке.
    /// Больше пачка — больше нужно свободного места; каждая пачка — одно системное подтверждение.
    static let batchSize = 200
    /// Запас свободного места сверх размера снимков: медиатеке нужно место и на превью.
    static let spaceMargin: Int64 = 200_000_000

    static func savings(total: Int64, still: Int64) -> Int64 {
        max(total - still, 0)
    }

    /// Какой ресурс станет снимком: у фото с правками (обрезка, фильтр, выключенный Live, другой главный кадр) —
    /// отрисованная версия, иначе исходный снимок.
    static func stillResourceType(among types: [PHAssetResourceType]) -> PHAssetResourceType? {
        if types.contains(.fullSizePhoto) { return .fullSizePhoto }
        if types.contains(.photo) { return .photo }
        return nil
    }

    /// Имя файла копии: имя исходного снимка (IMG_1234) и расширение выбранного ресурса.
    /// Версию с правками iOS называет FullSizeRender, поэтому основа имени берётся у исходника.
    static func filename(original: String?, chosen: String) -> String {
        guard let original, !original.isEmpty else { return chosen }
        let ext = (chosen as NSString).pathExtension
        guard !ext.isEmpty else { return original }
        return (original as NSString).deletingPathExtension + "." + ext
    }

    /// Хватит ли свободного места, чтобы на время положить снимки во временную папку, а потом в медиатеку.
    /// Оригиналы 30 дней лежат в «Недавно удалённых», поэтому место под копии нужно сразу.
    static func hasRoom(forStills bytes: Int64, available: Int64?) -> Bool {
        guard let available else { return true }
        return bytes + spaceMargin <= available
    }

    static func batches<Item>(_ items: [Item], size: Int = batchSize) -> [[Item]] {
        guard size > 0 else { return [items] }
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    /// Отмена в системном окне подтверждения — не ошибка: просто ничего не изменилось.
    static func isUserCancel(_ error: Error) -> Bool {
        (error as? PHPhotosError)?.code == .userCancelled
    }

    // MARK: - Поиск

    /// Фото с видео Live Photo. Скрытые не попадают: их не видно и в остальном приложении.
    static func fetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d AND (mediaSubtypes & %d) != 0",
            PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoLive.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    /// Все Live Photos медиатеки с размерами из кэша: на большой медиатеке первый раз это заметное время.
    /// Защищённые («Не трогать») не предлагаются: превращение заменяет оригинал новым фото.
    static func fetchCandidates(sparing protection: ProtectionPolicy = .current) -> [Candidate] {
        let result = PHAsset.fetchAssets(with: fetchOptions())
        var list: [Candidate] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            guard !protection.protects(asset) else { return }
            list.append(Candidate(asset: asset, total: asset.cachedTotalSize, still: asset.cachedFileSize))
        }
        FileSizeCache.shared.save()
        return list
    }

    // MARK: - Превращение

    /// Временная папка для снимков. Остатки прошлого запуска (если приложение закрыли посередине) удаляются.
    static func makeWorkDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-stills", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Выгружает снимок во временный файл без пережатия. Фото, которое лежит только в iCloud, скачивается.
    static func prepareStill(for asset: PHAsset, in directory: URL) async throws -> PreparedStill {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let type = stillResourceType(among: resources.map(\.type)),
              let resource = resources.first(where: { $0.type == type }) else { throw Failure.noStill }
        let name = filename(original: resources.first { $0.type == .photo }?.originalFilename, chosen: resource.originalFilename)
        let ext = (name as NSString).pathExtension
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext.isEmpty ? "heic" : ext)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { @Sendable error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard size > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw Failure.writeFailed
        }
        return PreparedStill(
            originalID: asset.localIdentifier,
            url: url,
            filename: name,
            originalTotal: asset.cachedTotalSize,
            size: size
        )
    }

    /// Одна транзакция: новые фото из снимков и удаление их оригиналов, одно системное подтверждение.
    /// При отмене PhotoKit не применяет ни одного изменения из блока, и функция бросает ошибку отмены.
    /// Оригиналы, которые успели удалить снаружи, пропускаются вместе со своими снимками.
    /// Блок изменений `@Sendable` и берёт фото по идентификаторам: PhotoKit выполняет его на своей очереди.
    static func commit(_ stills: [PreparedStill]) async throws -> Outcome {
        guard !stills.isEmpty else { return Outcome() }
        // Пишется только внутри блока, а читается после его успешного завершения.
        nonisolated(unsafe) var replaced: [String: String] = [:]
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            replaced = [:]
            var originals: [String: PHAsset] = [:]
            PHAsset.fetchAssets(withLocalIdentifiers: stills.map(\.originalID), options: nil).enumerateObjects { asset, _, _ in
                originals[asset.localIdentifier] = asset
            }
            var doomed: [PHAsset] = []
            for still in stills {
                guard let original = originals[still.originalID] else { continue }
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = still.filename
                options.shouldMoveFile = true
                request.addResource(with: .photo, fileURL: still.url, options: options)
                request.creationDate = original.creationDate
                request.location = original.location
                request.isFavorite = original.isFavorite
                request.isHidden = original.isHidden
                guard let placeholder = request.placeholderForCreatedAsset else { continue }
                PHAssetCollection.fetchAssetCollectionsContaining(original, with: .album, options: nil).enumerateObjects { album, _, _ in
                    guard album.canPerform(.addContent) else { return }
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
                replaced[still.originalID] = placeholder.localIdentifier
                doomed.append(original)
            }
            if !doomed.isEmpty {
                PHAssetChangeRequest.deleteAssets(doomed as NSArray)
            }
        }
        return outcome(replaced: replaced, stills: stills)
    }

    /// Итог транзакции: сколько освободилось у фото, которые действительно заменены.
    static func outcome(replaced: [String: String], stills: [PreparedStill]) -> Outcome {
        let saved = stills
            .filter { replaced[$0.originalID] != nil }
            .reduce(Int64(0)) { $0 + savings(total: $1.originalTotal, still: $1.size) }
        return Outcome(replaced: replaced, saved: saved)
    }
}
