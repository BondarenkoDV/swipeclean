import Foundation
import Photos
import SwiftUI

/// Раздел медиатеки на экране памяти. Каждое фото и видео попадает ровно в один раздел,
/// поэтому разделы складываются в размер всей медиатеки.
enum MediaKind: String, CaseIterable, Identifiable, Sendable {
    case photos
    case livePhotos
    case screenshots
    case bursts
    case portraits
    case panoramas
    case videos
    case slowMotion
    case timelapses
    case hidden

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .photos: "Фото"
        case .livePhotos: "Live Photos"
        case .screenshots: "Скриншоты"
        case .bursts: "Серии"
        case .portraits: "Портреты"
        case .panoramas: "Панорамы"
        case .videos: "Видео"
        case .slowMotion: "Замедленные видео"
        case .timelapses: "Таймлапсы"
        case .hidden: "Скрытые"
        }
    }

    var symbol: String {
        switch self {
        case .photos: "photo.fill"
        case .livePhotos: "livephoto"
        case .screenshots: "camera.viewfinder"
        case .bursts: "square.stack.3d.down.right"
        case .portraits: "person.crop.square"
        case .panoramas: "pano.fill"
        case .videos: "video.fill"
        case .slowMotion: "slowmo"
        case .timelapses: "timelapse"
        case .hidden: "eye.slash.fill"
        }
    }

    var tone: Tone {
        switch self {
        case .photos: .blue
        case .livePhotos: .yellow
        case .screenshots: .pink
        case .bursts: .teal
        case .portraits: .violet
        case .panoramas: .cyan
        case .videos: .red
        case .slowMotion: .orange
        case .timelapses: .green
        case .hidden: .indigo
        }
    }

    var isVideo: Bool {
        switch self {
        case .videos, .slowMotion, .timelapses: true
        default: false
        }
    }

    /// Порядок проверок задаёт, куда попадает фото с несколькими признаками: скрытое — в «Скрытые»,
    /// скриншот — в «Скриншоты», кадр серии — в «Серии», даже если это Live Photo или портрет.
    static func of(mediaType: PHAssetMediaType, subtypes: PHAssetMediaSubtype, isBurst: Bool, isHidden: Bool) -> MediaKind {
        if isHidden { return .hidden }
        if mediaType == .video {
            if subtypes.contains(.videoHighFrameRate) { return .slowMotion }
            if subtypes.contains(.videoTimelapse) { return .timelapses }
            return .videos
        }
        if subtypes.contains(.photoScreenshot) { return .screenshots }
        if isBurst { return .bursts }
        if subtypes.contains(.photoLive) { return .livePhotos }
        if subtypes.contains(.photoDepthEffect) { return .portraits }
        if subtypes.contains(.photoPanorama) { return .panoramas }
        return .photos
    }

    init(_ asset: PHAsset) {
        self = Self.of(
            mediaType: asset.mediaType,
            subtypes: asset.mediaSubtypes,
            isBurst: asset.burstIdentifier != nil,
            isHidden: asset.isHidden
        )
    }

    /// Все фото и видео: и скрытые, и каждый кадр серий, иначе размер медиатеки получился бы меньше настоящего.
    static func fetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.includeHiddenAssets = true
        return options
    }

    /// Фото и видео раздела, самые тяжёлые первыми. Скрытые не показываются: в Фото они закрыты Face ID.
    static func assets(of kind: MediaKind) -> [(asset: PHAsset, size: Int64)] {
        guard kind != .hidden else { return [] }
        var result: [(asset: PHAsset, size: Int64)] = []
        PHAsset.fetchAssets(with: fetchOptions()).enumerateObjects { asset, _, _ in
            if MediaKind(asset) == kind {
                result.append((asset, asset.cachedTotalSize))
            }
        }
        FileSizeCache.shared.save()
        return result.sorted { $0.size > $1.size }
    }
}

/// Сколько фото и видео в каждом разделе медиатеки и сколько места они занимают.
struct MediaBreakdown: Equatable, Sendable {
    struct Usage: Equatable, Sendable {
        var count = 0
        var bytes: Int64 = 0
    }

    private(set) var usage: [MediaKind: Usage] = [:]

    subscript(kind: MediaKind) -> Usage {
        usage[kind] ?? Usage()
    }

    var totalBytes: Int64 {
        usage.values.reduce(0) { $0 + $1.bytes }
    }

    var totalCount: Int {
        usage.values.reduce(0) { $0 + $1.count }
    }

    /// Непустые разделы, самые тяжёлые первыми.
    var kinds: [MediaKind] {
        MediaKind.allCases
            .filter { self[$0].count > 0 }
            .sorted { self[$0].bytes > self[$1].bytes }
    }

    mutating func add(_ kind: MediaKind, bytes: Int64) {
        usage[kind, default: Usage()].count += 1
        usage[kind, default: Usage()].bytes += bytes
    }

    /// Обходит всю медиатеку. Размеры берутся из кэша, первый раз на большой медиатеке это десятки секунд.
    static func measure() -> MediaBreakdown {
        var breakdown = MediaBreakdown()
        PHAsset.fetchAssets(with: MediaKind.fetchOptions()).enumerateObjects { asset, _, _ in
            breakdown.add(MediaKind(asset), bytes: asset.cachedTotalSize)
        }
        FileSizeCache.shared.save()
        return breakdown
    }
}

/// Сколько места занимает сам SwipeClean: секретная папка отдельно, остальное — само приложение,
/// кэш анализа и настройки.
struct AppFootprint: Equatable, Sendable {
    var vault: Int64 = 0
    var other: Int64 = 0

    var total: Int64 { vault + other }

    static func measure(vaultDirectory: URL) -> AppFootprint {
        let data = allocatedSize(of: URL(fileURLWithPath: NSHomeDirectory()))
        let bundle = allocatedSize(of: Bundle.main.bundleURL)
        let vault = allocatedSize(of: vaultDirectory)
        // Секретная папка лежит внутри данных приложения, поэтому вычитается из них.
        return AppFootprint(vault: vault, other: max(data + bundle - vault, 0))
    }

    /// Место на диске под все файлы папки, как его считает Finder.
    static func allocatedSize(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Из чего складывается занятое место. iOS не даёт приложениям узнать размеры других программ,
/// поэтому измеряются медиатека и SwipeClean, а всё остальное — приложения, система, кэши — остаётся одной строкой.
struct StorageBreakdown: Equatable, Sendable {
    let device: DeviceStorage
    let media: Int64
    let app: Int64

    /// Размеры фото считаются по оригиналам. С «Оптимизацией хранилища» часть оригиналов лежит только в iCloud,
    /// и медиатека может оказаться больше занятого места: тогда на iPhone ей отводится всё, что осталось после SwipeClean.
    var mediaOnDevice: Int64 {
        min(media, max(device.used - app, 0))
    }

    var other: Int64 {
        max(device.used - app - mediaOnDevice, 0)
    }

    /// Медиатека с оригиналами не помещается в занятое место: значит, часть фото хранится только в iCloud.
    var isMediaPartlyInCloud: Bool {
        media + app > device.used
    }

    /// Доли от всей памяти для полосы: медиа, SwipeClean, остальное и свободное в сумме дают единицу.
    func fraction(_ bytes: Int64) -> Double {
        device.total > 0 ? Double(max(bytes, 0)) / Double(device.total) : 0
    }

    /// Сколько места на iPhone приходится на раздел медиатеки, если вся медиатека не помещается в занятое место.
    func onDevice(_ bytes: Int64) -> Int64 {
        guard media > 0 else { return 0 }
        return Int64(Double(bytes) * Double(mediaOnDevice) / Double(media))
    }
}
