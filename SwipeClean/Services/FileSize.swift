import Foundation
import Photos

extension PHAsset {
    /// Размер основного ресурса в байтах.
    /// Публичного быстрого API нет: берём недокументированное свойство `fileSize` ресурса,
    /// как делают другие приложения для чистки. Если в новой iOS его не станет,
    /// возвращается оценка по разрешению и длительности, а не nil.
    var fileSize: Int64? {
        resourceSizes?.primary ?? estimatedFileSize
    }

    /// Основной и все ресурсы за один запрос; nil, если у основного ресурса нет размера.
    fileprivate var resourceSizes: (primary: Int64, total: Int64)? {
        let resources = PHAssetResource.assetResources(for: self)
        let primary = resources.first { $0.type == .photo || $0.type == .video || $0.type == .audio } ?? resources.first
        guard let primary, let primarySize = Self.size(of: primary) else { return nil }
        let total = resources.reduce(Int64(0)) { $0 + (Self.size(of: $1) ?? 0) }
        return (primarySize, max(total, primarySize))
    }

    private static func size(of resource: PHAssetResource) -> Int64? {
        guard resource.responds(to: NSSelectorFromString("fileSize")),
              let value = (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value, value > 0 else { return nil }
        return value
    }

    /// Грубая оценка: HEIC около 0,3 байта на пиксель, видео около 1 МБ/с на каждые 2 Мп кадра.
    var estimatedFileSize: Int64? {
        let pixels = Double(pixelWidth * pixelHeight)
        guard pixels > 0 else { return nil }
        switch mediaType {
        case .video:
            let bytesPerSecond = max(pixels / 2_000_000, 0.25) * 1_000_000
            return Int64(duration * bytesPerSecond)
        default:
            return Int64(pixels * 0.3)
        }
    }

    /// Размер из кэша, если фото не менялось с прошлого раза; иначе считается и запоминается.
    var cachedFileSize: Int64 {
        FileSizeCache.shared.size(of: self)
    }

    /// Размер всех ресурсов вместе, из того же кэша: у Live Photo к фото добавляется видео,
    /// у изменённого фото — оригинал и версия с правками. Столько фото занимает в медиатеке на самом деле.
    var cachedTotalSize: Int64 {
        FileSizeCache.shared.totalSize(of: self)
    }
}

/// Кэш размеров файлов в Caches/file-sizes.plist. «Крупные файлы» и «Тяжёлые видео»
/// иначе опрашивают ресурсы каждого ассета при каждом открытии, а это десятки секунд на большой медиатеке.
final class FileSizeCache: @unchecked Sendable {
    static let shared = FileSizeCache()

    private struct Entry: Codable {
        var size: Int64
        /// Все ресурсы вместе. В записях старых версий его нет: тогда он досчитывается по первому запросу.
        var total: Int64?
        var modified: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [String: Entry]
    private var isDirty = false

    private static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("file-sizes.plist")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.url),
           let entries = try? PropertyListDecoder().decode([String: Entry].self, from: data) {
            self.entries = entries
        } else {
            entries = [:]
        }
    }

    func size(of asset: PHAsset) -> Int64 {
        entry(for: asset, needsTotal: false).size
    }

    func totalSize(of asset: PHAsset) -> Int64 {
        let entry = entry(for: asset, needsTotal: true)
        return entry.total ?? entry.size
    }

    /// Ресурсы опрашиваются один раз и сразу на оба размера.
    private func entry(for asset: PHAsset, needsTotal: Bool) -> Entry {
        let id = asset.localIdentifier
        let modified = asset.modificationDate?.timeIntervalSince1970 ?? 0
        lock.lock()
        let cached = entries[id]
        lock.unlock()
        if let cached, cached.modified == modified, !needsTotal || cached.total != nil { return cached }
        let estimate = asset.estimatedFileSize ?? 0
        let sizes = asset.resourceSizes ?? (primary: estimate, total: estimate)
        let entry = Entry(size: sizes.primary, total: sizes.total, modified: modified)
        lock.lock()
        entries[id] = entry
        isDirty = true
        lock.unlock()
        return entry
    }

    func save() {
        lock.lock()
        defer { lock.unlock() }
        guard isDirty else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: Self.url, options: .atomic)
        isDirty = false
    }

    func clear() {
        lock.lock()
        entries = [:]
        isDirty = false
        lock.unlock()
        try? FileManager.default.removeItem(at: Self.url)
    }
}
