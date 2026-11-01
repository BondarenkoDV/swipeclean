import Photos
import SwiftUI

/// Состояние стопки карточек: текущая позиция, решения и история для undo.
@MainActor
@Observable
final class SwipeDeckViewModel {
    struct Action {
        let asset: PHAsset
        let decision: SwipeDecision
        /// Альбом, в который фото положили вместо обычного «оставить».
        var albumID: String?
    }

    let title: String
    private(set) var assets: [PHAsset]
    private(set) var index = 0
    private(set) var history: [Action] = []
    private(set) var counts: [SwipeDecision: Int] = [:]
    /// Сколько места освободится, когда отправленное в корзину в этой стопке удалят из медиатеки.
    private(set) var trashBytes: Int64 = 0
    /// Последняя взятая веха (100 МБ, 1 ГБ…) и счётчик вех: по нему экран хвалит и даёт вибрацию.
    private(set) var milestone: Int64?
    private(set) var milestoneCount = 0
    private var trashedIDs: Set<String> = []
    private var sizes: [String: Int64] = [:]
    private var bestMilestone: Int64 = 0

    static let undoLimit = 20
    static let prefetchCount = 5
    /// Вехи, на которых стопка хвалит. После 10 ГБ — каждые следующие 5 ГБ.
    static let milestones: [Int64] = [50, 100, 250, 500, 1024, 2048, 5120, 10240].map { $0 * 1024 * 1024 }

    init(title: String, assets: [PHAsset]) {
        self.title = title
        self.assets = assets
        prefetch()
    }

    var current: PHAsset? { assets[safe: index] }
    var next: PHAsset? { assets[safe: index + 1] }
    var isFinished: Bool { index >= assets.count }
    var canUndo: Bool { !history.isEmpty }

    var progress: Double {
        assets.isEmpty ? 1 : Double(index) / Double(assets.count)
    }

    @discardableResult
    func decide(_ decision: SwipeDecision, albumID: String? = nil) -> Action? {
        guard let asset = current else { return nil }
        let action = Action(asset: asset, decision: decision, albumID: albumID)
        history.append(action)
        if history.count > Self.undoLimit {
            history.removeFirst()
        }
        counts[decision, default: 0] += 1
        index += 1
        if decision == .trash {
            trashedIDs.insert(asset.localIdentifier)
            measure(asset)
        }
        prefetch()
        return action
    }

    @discardableResult
    func undo() -> Action? {
        guard let last = history.popLast() else { return nil }
        counts[last.decision, default: 1] -= 1
        index = max(0, index - 1)
        if last.decision == .trash {
            trashedIDs.remove(last.asset.localIdentifier)
            updateTrashBytes()
        }
        return last
    }

    /// Размер файла считается вне главного потока: у фото из iCloud запрос ресурсов бывает небыстрым.
    private func measure(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if sizes[id] != nil {
            updateTrashBytes()
            return
        }
        Task {
            let size = await Task.detached(priority: .userInitiated) { asset.cachedFileSize }.value
            sizes[id] = size
            updateTrashBytes()
        }
    }

    private func updateTrashBytes() {
        trashBytes = trashedIDs.reduce(0) { $0 + (sizes[$1] ?? 0) }
        guard let reached = Self.milestone(for: trashBytes), reached > bestMilestone else { return }
        bestMilestone = reached
        milestone = reached
        milestoneCount += 1
    }

    /// Наибольшая веха, которую уже прошли: из списка, а после 10 ГБ — кратная 5 ГБ.
    static func milestone(for bytes: Int64) -> Int64? {
        let step: Int64 = 5 * 1024 * 1024 * 1024
        if let last = milestones.last, bytes >= last + step {
            return bytes / step * step
        }
        return milestones.last { $0 <= bytes }
    }

    /// Убирает из ещё не показанных карточек фото, которых больше нет в медиатеке
    /// (удалены в другом приложении), чтобы не показывать вечную загрузку.
    /// Проверка идёт в фоне: в «Все фото» это десятки тысяч идентификаторов, а вызывается она
    /// на каждое изменение медиатеки, в том числе после каждого свайпа в избранное.
    func dropMissing() async {
        let ids = assets.dropFirst(index).map(\.localIdentifier)
        guard !ids.isEmpty else { return }
        let missing = await Task.detached(priority: .utility) { LibraryFetcher.missingIDs(ids) }.value
        guard !missing.isEmpty else { return }
        // Пока шла проверка, пользователь мог свайпнуть дальше: уже показанные карточки не трогаем,
        // иначе отмена вернула бы не то фото.
        let upcoming = assets.dropFirst(index)
        assets = Array(assets.prefix(index)) + upcoming.filter { !missing.contains($0.localIdentifier) }
        prefetch()
    }

    /// Убирает защищённые фото из текущей и следующих карточек: их приложение не предлагает разбирать.
    /// Уже разобранные карточки остаются на месте, чтобы отмена возвращала то же фото.
    func dropProtected(_ policy: ProtectionPolicy) {
        guard !policy.isEmpty else { return }
        let upcoming = assets.dropFirst(index)
        guard upcoming.contains(where: { policy.protects($0) }) else { return }
        assets = Array(assets.prefix(index)) + upcoming.filter { !policy.protects($0) }
        prefetch()
    }

    /// Предзагрузка в том же размере, в котором карточка запрашивает изображение, иначе кэш не используется.
    private func prefetch() {
        let loader = AssetImageLoader.shared
        let size = loader.cardTargetSize
        let upcoming = Array(assets.dropFirst(index).prefix(Self.prefetchCount))
        loader.startCaching(upcoming, targetSize: size)
        let passed = Array(assets.prefix(max(0, index - 1)).suffix(Self.prefetchCount))
        loader.stopCaching(passed, targetSize: size)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
