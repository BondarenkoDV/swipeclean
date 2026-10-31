import Photos

/// Подборка для разбора.
enum LibrarySource: Hashable, Identifiable {
    case all
    case random
    case onThisDay
    case videos
    case screenshots
    case selfies
    case livePhotos
    case largeFiles
    case later
    case month(year: Int, month: Int)
    case album(id: String, title: String)

    var id: String {
        switch self {
        case let .month(year, month): "month-\(year)-\(month)"
        case let .album(id, _): "album-\(id)"
        default: String(describing: self)
        }
    }

    var title: String {
        switch self {
        case .all: String(localized: "Все фото")
        case .random: String(localized: "Случайно")
        case .onThisDay: String(localized: "В этот день")
        case .videos: String(localized: "Видео")
        case .screenshots: String(localized: "Скриншоты")
        case .selfies: String(localized: "Селфи")
        case .livePhotos: "Live Photos"
        case .largeFiles: String(localized: "Крупные файлы")
        case .later: String(localized: "Решу позже")
        case let .month(year, month): Self.monthTitle(year: year, month: month)
        case let .album(_, title): title
        }
    }

    var symbol: String {
        switch self {
        case .all: "photo.stack"
        case .random: "shuffle"
        case .onThisDay: "calendar"
        case .videos: "video"
        case .screenshots: "camera.viewfinder"
        case .selfies: "person.crop.square"
        case .livePhotos: "livephoto"
        case .largeFiles: "externaldrive"
        case .later: "clock"
        case .month: "calendar"
        case .album: "rectangle.stack"
        }
    }

    static let featured: [LibrarySource] = [
        .all, .random, .onThisDay, .videos, .screenshots, .selfies, .livePhotos, .largeFiles,
    ]

    static func monthTitle(year: Int, month: Int) -> String {
        let components = DateComponents(year: year, month: month, day: 1)
        guard let date = Calendar.current.date(from: components) else { return "\(month).\(year)" }
        return date.formatted(.dateTime.month(.wide).year()).capitalized
    }
}

/// Загрузка ассетов для подборок. Работает вне главного потока.
enum LibraryFetcher {
    static let largeFilesLimit = 300

    static func fetch(_ source: LibrarySource) -> [PHAsset] {
        switch source {
        case .all:
            return assets(fetchAll())
        case .random:
            return assets(fetchAll()).shuffled()
        case .onThisDay:
            let calendar = Calendar.current
            let today = calendar.dateComponents([.month, .day], from: .now)
            let thisYear = calendar.component(.year, from: .now)
            return assets(fetchAll()).filter { asset in
                guard let date = asset.creationDate else { return false }
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                return parts.month == today.month && parts.day == today.day && parts.year != thisYear
            }
        case .videos:
            return assets(fetchAll(mediaType: .video))
        case .screenshots:
            return smartAlbum(.smartAlbumScreenshots)
        case .selfies:
            return smartAlbum(.smartAlbumSelfPortraits)
        case .livePhotos:
            return smartAlbum(.smartAlbumLivePhotos)
        case .largeFiles:
            let sized = assets(fetchAll()).map { ($0, $0.cachedFileSize) }
            FileSizeCache.shared.save()
            return sized
                .sorted { $0.1 > $1.1 }
                .prefix(largeFilesLimit)
                .map(\.0)
        case .later:
            // Список берётся из ReviewStore, см. fetch(ids:).
            return []
        case let .month(year, month):
            let calendar = Calendar.current
            guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else { return [] }
            let options = sortedOptions()
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
            return assets(PHAsset.fetchAssets(with: options))
        case let .album(id, _):
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else { return [] }
            return assets(PHAsset.fetchAssets(in: collection, options: sortedOptions()))
        }
    }

    static func fetch(ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        return assets(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: sortedOptions()))
    }

    /// Ассеты по идентификаторам; те, которых больше нет в медиатеке, в словарь не попадают.
    static func assetsByID(_ ids: [String]) -> [String: PHAsset] {
        guard !ids.isEmpty else { return [:] }
        var byID: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            byID[asset.localIdentifier] = asset
        }
        return byID
    }

    /// Какие из идентификаторов больше не существуют в медиатеке.
    static func missingIDs(_ ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let existing = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard existing.count < ids.count else { return [] }
        var missing = Set(ids)
        existing.enumerateObjects { asset, _, _ in missing.remove(asset.localIdentifier) }
        return missing
    }

    /// Месяцы с количеством ассетов, от новых к старым.
    static func months() -> [MonthBucket] {
        let calendar = Calendar.current
        var buckets: [MonthKey: [String]] = [:]
        fetchAll().enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            let parts = calendar.dateComponents([.year, .month], from: date)
            guard let year = parts.year, let month = parts.month else { return }
            buckets[MonthKey(year: year, month: month), default: []].append(asset.localIdentifier)
        }
        return buckets
            .map { MonthBucket(year: $0.key.year, month: $0.key.month, assetIDs: $0.value) }
            .sorted { ($0.year, $0.month) > ($1.year, $1.month) }
    }

    private static func fetchAll(mediaType: PHAssetMediaType? = nil) -> PHFetchResult<PHAsset> {
        let options = sortedOptions()
        if let mediaType {
            return PHAsset.fetchAssets(with: mediaType, options: options)
        }
        return PHAsset.fetchAssets(with: options)
    }

    private static func smartAlbum(_ subtype: PHAssetCollectionSubtype) -> [PHAsset] {
        guard let album = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject else { return [] }
        return assets(PHAsset.fetchAssets(in: album, options: sortedOptions()))
    }

    private static func sortedOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    private static func assets(_ result: PHFetchResult<PHAsset>) -> [PHAsset] {
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        return list
    }
}

private struct MonthKey: Hashable {
    let year: Int
    let month: Int
}

struct MonthBucket: Identifiable, Hashable {
    let year: Int
    let month: Int
    let assetIDs: [String]

    var id: String { "\(year)-\(month)" }
    var source: LibrarySource { .month(year: year, month: month) }
}
