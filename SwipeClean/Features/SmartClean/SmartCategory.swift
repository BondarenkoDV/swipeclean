import Photos
import SwiftUI

/// Категория умной чистки фото и видео: название, цвет плитки и что в ней лишнее.
/// Видео удаляются общей кнопкой только точными копиями; тяжёлые видео пользователь выбирает сам.
enum SmartCategory: String, CaseIterable, Identifiable {
    case similar
    case duplicates
    case bursts
    case blurry
    case screenshots
    case videoDuplicates
    case heavyVideos

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .similar: "Похожие"
        case .duplicates: "Дубликаты"
        case .bursts: "Серии"
        case .blurry: "Размытые"
        case .screenshots: "Старые скриншоты"
        case .videoDuplicates: "Дубликаты видео"
        case .heavyVideos: "Тяжёлые видео"
        }
    }

    var symbol: String {
        switch self {
        case .similar: "square.on.square"
        case .duplicates: "plus.square.on.square"
        case .bursts: "square.stack.3d.down.right"
        case .blurry: "camera.metering.unknown"
        case .screenshots: "camera.viewfinder"
        case .videoDuplicates: "film.stack"
        case .heavyVideos: "externaldrive.badge.exclamationmark"
        }
    }

    var tone: Tone {
        switch self {
        case .similar: .violet
        case .duplicates: .blue
        case .bursts: .teal
        case .blurry: .orange
        case .screenshots: .pink
        case .videoDuplicates: .red
        case .heavyVideos: .yellow
        }
    }

    /// Только ручной выбор: большие видео — не мусор. Их не считают лишним, не выделяют заранее
    /// и не убирают общей кнопкой: пользователь сам решает, какие удалить.
    var isManualOnly: Bool {
        self == .heavyVideos
    }

    /// Категории, которые считаются лишним: в итогах умной чистки и на главной.
    static var clutter: [SmartCategory] {
        allCases.filter { !$0.isManualOnly }
    }

    var isGroups: Bool {
        switch self {
        case .similar, .duplicates, .bursts, .videoDuplicates: true
        case .blurry, .screenshots, .heavyVideos: false
        }
    }

    @MainActor
    func groups(in analyzer: SmartCleanAnalyzer) -> [AssetGroup] {
        switch self {
        case .similar: analyzer.similar
        case .duplicates: analyzer.duplicates
        case .bursts: analyzer.bursts
        case .videoDuplicates: analyzer.videoDuplicates
        case .blurry, .screenshots, .heavyVideos: []
        }
    }

    @MainActor
    func assets(in analyzer: SmartCleanAnalyzer) -> [PHAsset] {
        switch self {
        case .blurry: analyzer.blurry
        case .screenshots: analyzer.oldScreenshots
        case .heavyVideos: analyzer.heavyVideos
        case .similar, .duplicates, .bursts, .videoDuplicates: []
        }
    }

    /// Что предлагается убрать: лишние кадры групп или все найденные фото.
    @MainActor
    func extras(in analyzer: SmartCleanAnalyzer) -> [PHAsset] {
        isGroups ? groups(in: analyzer).flatMap(\.others) : assets(in: analyzer)
    }

    @MainActor
    func detail(in analyzer: SmartCleanAnalyzer) -> String {
        if isGroups {
            let groups = groups(in: analyzer)
            let extra = groups.reduce(0) { $0 + $1.others.count }
            return groups.isEmpty ? "0" : String(localized: "\(groups.count) гр. · \(extra) лишних")
        }
        return "\(assets(in: analyzer).count)"
    }

    @MainActor @ViewBuilder
    func destination(analyzer: SmartCleanAnalyzer) -> some View {
        if isGroups {
            GroupsView(title: title, groups: groups(in: analyzer), analyzer: analyzer)
        } else {
            SelectionGridView(title: title, assets: assets(in: analyzer), analyzer: analyzer)
        }
    }

    /// Размер лишнего по категориям. Размеры берутся из кэша, первый раз считаются вне главного потока.
    static func extraBytes(_ extras: [SmartCategory: [PHAsset]]) async -> [SmartCategory: Int64] {
        await Task.detached(priority: .utility) {
            var bytes: [SmartCategory: Int64] = [:]
            for (category, assets) in extras {
                bytes[category] = assets.reduce(0) { $0 + $1.cachedFileSize }
            }
            FileSizeCache.shared.save()
            return bytes
        }.value
    }
}
