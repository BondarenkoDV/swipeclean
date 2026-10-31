import Foundation
import Photos

/// Сколько места на iPhone всего и сколько свободно.
struct DeviceStorage: Equatable, Sendable {
    let total: Int64
    let available: Int64
    /// Кэши, которые iOS удалит сама, когда понадобится место. Они уже входят в `available`.
    var purgeable: Int64 = 0

    var used: Int64 { max(total - available, 0) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    /// Свободное место считается «для важного», как в Настройках: iOS может освободить кэши ради новых фото.
    /// Разница с просто свободным местом и есть такие кэши.
    static func current() -> DeviceStorage? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let available = min(values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(total))
        let free = Int64(values.volumeAvailableCapacity ?? 0)
        return DeviceStorage(total: Int64(total), available: available, purgeable: max(available - free, 0))
    }
}

/// Сводка по медиатеке для главного экрана.
struct MediaSummary: Equatable, Sendable {
    var photos = 0
    var videos = 0
    var screenshots = 0
    var livePhotos = 0
    /// Сколько занимают все фото и видео; nil, пока размеры считаются.
    var bytes: Int64?
    /// Из чего складывается `bytes`: для экрана памяти.
    var breakdown: MediaBreakdown?

    /// Количества берутся из PhotoKit мгновенно, размеры — отдельно, см. `withBytes()`.
    static func counts() -> MediaSummary {
        var summary = MediaSummary()
        summary.photos = PHAsset.fetchAssets(with: .image, options: nil).count
        summary.videos = PHAsset.fetchAssets(with: .video, options: nil).count
        summary.screenshots = smartAlbumCount(.smartAlbumScreenshots)
        summary.livePhotos = smartAlbumCount(.smartAlbumLivePhotos)
        return summary
    }

    /// Размер всех файлов. Первый раз на большой медиатеке это десятки секунд, дальше размеры берутся из кэша.
    func withBytes() -> MediaSummary {
        let breakdown = MediaBreakdown.measure()
        var summary = self
        summary.bytes = breakdown.totalBytes
        summary.breakdown = breakdown
        return summary
    }

    private static func smartAlbumCount(_ subtype: PHAssetCollectionSubtype) -> Int {
        guard let album = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject else { return 0 }
        return PHAsset.fetchAssets(in: album, options: nil).count
    }
}
