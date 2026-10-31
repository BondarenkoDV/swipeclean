import AVFoundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Насколько сильно сжимать: чем ниже уровень, тем меньше файл и заметнее потери.
enum CompressionLevel: String, CaseIterable, Identifiable, Sendable {
    case high
    case medium
    case low

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: String(localized: "Высокое")
        case .medium: String(localized: "Среднее")
        case .low: String(localized: "Низкое")
        }
    }

    var photoDetail: String {
        switch self {
        case .high: String(localized: "Исходное разрешение, почти без потерь")
        case .medium: String(localized: "До 12 Мп, разница видна только при увеличении")
        case .low: String(localized: "До 4 Мп, для фото «на память»")
        }
    }

    var videoDetail: String {
        switch self {
        case .high: String(localized: "До 1080p в HEVC")
        case .medium: String(localized: "До 720p")
        case .low: String(localized: "До 540p, самый маленький файл")
        }
    }

    /// Качество HEIC/JPEG от 0 до 1.
    var photoQuality: Double {
        switch self {
        case .high: 0.75
        case .medium: 0.6
        case .low: 0.45
        }
    }

    /// Длинная сторона фото после сжатия; nil — оставить исходную.
    var photoMaxSide: CGFloat? {
        switch self {
        case .high: nil
        case .medium: 4032
        case .low: 2400
        }
    }

    /// Пресеты экспорта по порядку предпочтения: если первого нет на устройстве, берётся следующий.
    var videoPresets: [String] {
        switch self {
        case .high: [AVAssetExportPresetHEVC1920x1080, AVAssetExportPreset1920x1080]
        case .medium: [AVAssetExportPreset1280x720]
        case .low: [AVAssetExportPreset960x540]
        }
    }

    /// Примерный битрейт видео после сжатия, бит/с: только для оценки экономии до начала.
    var videoBitrate: Double {
        switch self {
        case .high: 7_000_000
        case .medium: 4_500_000
        case .low: 2_000_000
        }
    }

    /// Примерная доля от исходного размера фото, тоже только для оценки.
    var photoRatio: Double {
        switch self {
        case .high: 0.55
        case .medium: 0.35
        case .low: 0.2
        }
    }
}

/// Сжатие фото и видео: новая копия сохраняется в медиатеку с той же датой, местом, избранным и альбомами,
/// а оригинал удаляется отдельно, одним системным подтверждением на всю пачку.
enum MediaCompressor {
    struct Outcome: Sendable {
        let originalID: String
        let copyID: String
        let originalSize: Int64
        let newSize: Int64
        var saved: Int64 { max(originalSize - newSize, 0) }
    }

    enum Failure: Error, Equatable {
        case missing
        case noData
        case encodeFailed
        /// Сжатая копия получилась не меньше чем на 10 %: оригинал выгоднее оставить как есть.
        case notSmaller
        case exportFailed
    }

    /// Копия должна быть хотя бы на 10 % меньше, иначе возня не стоит потерь качества.
    static let minimumGain = 0.9

    /// Оценка размера после сжатия до того, как что-то сжато.
    static func estimatedSize(of asset: PHAsset, size: Int64, level: CompressionLevel) -> Int64 {
        switch asset.mediaType {
        case .video:
            let byBitrate = Int64(asset.duration * level.videoBitrate / 8)
            return min(size, byBitrate)
        default:
            return Int64(Double(size) * level.photoRatio)
        }
    }

    static func compress(_ asset: PHAsset, level: CompressionLevel) async throws -> Outcome {
        asset.mediaType == .video
            ? try await compressVideo(asset, level: level)
            : try await compressPhoto(asset, level: level)
    }

    // MARK: - Фото

    private static func compressPhoto(_ asset: PHAsset, level: CompressionLevel) async throws -> Outcome {
        let id = asset.localIdentifier
        let originalSize = asset.fileSize ?? 0
        guard let data = await imageData(for: asset) else { throw Failure.noData }
        guard let encoded = encodePhoto(data, level: level) else { throw Failure.encodeFailed }
        let newSize = Int64(encoded.data.count)
        guard originalSize == 0 || Double(newSize) < Double(originalSize) * minimumGain else { throw Failure.notSmaller }
        let name = baseFilename(of: asset) + "." + (encoded.type.preferredFilenameExtension ?? "heic")
        guard let copyID = try await saveCopy(of: id, resource: .photo(encoded.data, filename: name)) else { throw Failure.encodeFailed }
        return Outcome(originalID: id, copyID: copyID, originalSize: originalSize, newSize: newSize)
    }

    /// Пережимает фото в HEIC (на устройствах без кодека — в JPEG), сохраняя EXIF и геометку.
    /// Поворот «запекается» в пиксели, поэтому ориентация в метаданных сбрасывается на обычную.
    static func encodePhoto(_ data: Data, level: CompressionLevel) -> (data: Data, type: UTType)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let longSide = max(width, height)
        guard longSide > 0 else { return nil }
        let target = min(level.photoMaxSide.map(Double.init) ?? longSide, longSide)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        var metadata: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] {
            if let value = properties[key] { metadata[key] = value }
        }
        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        metadata[kCGImagePropertyOrientation] = 1
        metadata[kCGImageDestinationLossyCompressionQuality] = level.photoQuality

        for type in [UTType.heic, .jpeg] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
            if CGImageDestinationFinalize(destination), output.length > 0 {
                return (output as Data, type)
            }
        }
        return nil
    }

    /// Данные текущей версии фото (с правками), с загрузкой оригинала из iCloud.
    private static func imageData(for asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { @Sendable data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - Видео

    private static func compressVideo(_ asset: PHAsset, level: CompressionLevel) async throws -> Outcome {
        let id = asset.localIdentifier
        let originalSize = asset.fileSize ?? 0
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        var exported = false
        for preset in level.videoPresets {
            guard let session = await exportSession(for: asset, preset: preset)?.value else { continue }
            if try await export(session, to: url) {
                exported = true
                break
            }
        }
        guard exported else { throw Failure.exportFailed }

        let newSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard newSize > 0 else { throw Failure.exportFailed }
        guard originalSize == 0 || Double(newSize) < Double(originalSize) * minimumGain else { throw Failure.notSmaller }
        guard let copyID = try await saveCopy(of: id, resource: .video(url, filename: baseFilename(of: asset) + ".mp4")) else {
            throw Failure.exportFailed
        }
        return Outcome(originalID: id, copyID: copyID, originalSize: originalSize, newSize: newSize)
    }

    /// Сессия экспорта от PhotoKit: он сам скачивает видео из iCloud и собирает замедленные ролики.
    private static func exportSession(for asset: PHAsset, preset: String) async -> Handoff<AVAssetExportSession>? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestExportSession(forVideo: asset, options: options, exportPreset: preset) { @Sendable session, _ in
                continuation.resume(returning: session.map(Handoff.init))
            }
        }
    }

    /// Возвращает false, если пресет не подошёл к этому ролику (тогда пробуем следующий).
    private static func export(_ session: AVAssetExportSession, to url: URL) async throws -> Bool {
        try? FileManager.default.removeItem(at: url)
        session.shouldOptimizeForNetworkUse = true
        if #available(iOS 18.0, *) {
            do {
                try await session.export(to: url, as: .mp4)
                return true
            } catch {
                if Task.isCancelled { throw CancellationError() }
                return false
            }
        } else {
            session.outputURL = url
            session.outputFileType = .mp4
            await session.export()
            if Task.isCancelled { throw CancellationError() }
            return session.status == .completed
        }
    }

    // MARK: - Сохранение копии

    enum Resource: Sendable {
        case photo(Data, filename: String)
        case video(URL, filename: String)
    }

    /// Сохраняет копию с датой, местом и избранным оригинала и добавляет её в те же альбомы.
    /// Блок изменений `@Sendable` и берёт оригинал по идентификатору: PhotoKit выполняет его на своей очереди.
    static func saveCopy(of originalID: String, resource: Resource) async throws -> String? {
        // Пишется только внутри блока, а читается после его завершения.
        nonisolated(unsafe) var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            guard let original = PHAsset.fetchAssets(withLocalIdentifiers: [originalID], options: nil).firstObject else { return }
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            switch resource {
            case let .photo(data, filename):
                options.originalFilename = filename
                request.addResource(with: .photo, data: data, options: options)
            case let .video(url, filename):
                options.originalFilename = filename
                request.addResource(with: .video, fileURL: url, options: options)
            }
            request.creationDate = original.creationDate
            request.location = original.location
            request.isFavorite = original.isFavorite
            guard let placeholder = request.placeholderForCreatedAsset else { return }
            placeholderID = placeholder.localIdentifier
            PHAssetCollection.fetchAssetCollectionsContaining(original, with: .album, options: nil).enumerateObjects { album, _, _ in
                guard album.canPerform(.addContent) else { return }
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        }
        return placeholderID
    }

    private static func baseFilename(of asset: PHAsset) -> String {
        let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "IMG"
        return (name as NSString).deletingPathExtension
    }
}

/// Передача объекта, который создатель отдаёт и больше не трогает (сессия из колбэка PhotoKit,
/// только что прочитанная картинка), из одной задачи в другую. Передача владения безопасна,
/// хотя сам класс не помечен Sendable.
struct Handoff<Value>: @unchecked Sendable {
    let value: Value
}
