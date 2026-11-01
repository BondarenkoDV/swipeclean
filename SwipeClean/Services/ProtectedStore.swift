import Foundation
import os
import Photos

/// Какие фото и видео приложение никогда не предлагает удалить: список «Не трогать» и, если включено, избранное.
/// Снимок неизменяемый, его можно отдавать в фоновые задачи.
struct ProtectionPolicy: Sendable, Equatable {
    var ids: Set<String> = []
    var includesFavorites = false

    /// Ничего не защищено.
    static let nothing = ProtectionPolicy()

    var isEmpty: Bool {
        ids.isEmpty && !includesFavorites
    }

    func protects(id: String, isFavorite: Bool) -> Bool {
        ids.contains(id) || (includesFavorites && isFavorite)
    }

    func protects(_ asset: PHAsset) -> Bool {
        protects(id: asset.localIdentifier, isFavorite: asset.isFavorite)
    }

    /// Защищённые среди идентификаторов. Избранное проверяется по медиатеке сейчас, а не по старому снимку ассета.
    func protectedIDs(among candidates: [String]) -> Set<String> {
        guard !candidates.isEmpty, !isEmpty else { return [] }
        var result = ids.intersection(candidates)
        guard includesFavorites else { return result }
        PHAsset.fetchAssets(withLocalIdentifiers: candidates, options: nil).enumerateObjects { asset, _, _ in
            if asset.isFavorite { result.insert(asset.localIdentifier) }
        }
        return result
    }

    /// Идентификаторы всего избранного в медиатеке.
    static func favoriteIDs() -> Set<String> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "favorite == YES")
        var ids: Set<String> = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        return ids
    }

    // MARK: - Текущий снимок для фоновых задач

    private static let shared = OSAllocatedUnfairLock(initialState: ProtectionPolicy.nothing)

    /// Действующая защита. Её читают код вне главного потока (удаление из медиатеки, подбор фото для сжатия)
    /// и анализ умной чистки, когда заканчивает работу.
    static var current: ProtectionPolicy {
        shared.withLock { $0 }
    }

    static func publish(_ policy: ProtectionPolicy) {
        shared.withLock { $0 = policy }
    }
}

/// Список «Не трогать». Защищённых фото нет в свайп-разборе, умной чистке, корзине, разделах памяти и сжатии,
/// а удаление из медиатеки их пропускает. Хранится отдельным файлом: сброс прогресса защиту не снимает.
@MainActor
@Observable
final class ProtectedStore {
    nonisolated static let favoritesKey = "protectFavorites"

    private(set) var ids: Set<String>
    /// Избранное из «Фото» тоже не трогать. Включено по умолчанию: избранное почти всегда то, что жалко потерять.
    private(set) var protectsFavorites: Bool

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let publishesPolicy: Bool

    /// - Parameters:
    ///   - uiTesting: в UI-тестах список живёт только в памяти и каждый запуск начинается пустым.
    ///   - fileURL: где хранить список; по умолчанию в Application Support.
    ///   - publishesPolicy: делать ли этот список действующим для всего приложения (`ProtectionPolicy.current`).
    init(
        uiTesting: Bool = SwipeCleanApp.isUITesting,
        fileURL: URL? = nil,
        defaults: UserDefaults = .standard,
        publishesPolicy: Bool = true
    ) {
        let url = uiTesting ? nil : (fileURL ?? Self.defaultFileURL)
        self.fileURL = url
        self.defaults = defaults
        self.publishesPolicy = publishesPolicy
        ids = url.flatMap(Self.load) ?? []
        protectsFavorites = defaults.object(forKey: Self.favoritesKey) as? Bool ?? true
        publish()
    }

    var policy: ProtectionPolicy {
        ProtectionPolicy(ids: ids, includesFavorites: protectsFavorites)
    }

    var count: Int { ids.count }

    func contains(_ id: String) -> Bool {
        ids.contains(id)
    }

    func protects(_ asset: PHAsset) -> Bool {
        policy.protects(asset)
    }

    func setProtectsFavorites(_ value: Bool) {
        guard value != protectsFavorites else { return }
        protectsFavorites = value
        defaults.set(value, forKey: Self.favoritesKey)
        publish()
    }

    func add(_ newIDs: some Sequence<String>) {
        let updated = ids.union(newIDs)
        guard updated != ids else { return }
        ids = updated
        save()
    }

    func remove(_ removed: some Sequence<String>) {
        let updated = ids.subtracting(removed)
        guard updated != ids else { return }
        ids = updated
        save()
    }

    /// Защищает фото и сразу возвращает их из корзины приложения: защищённое не может ждать удаления.
    func protect(_ newIDs: [String], store: ReviewStore) {
        add(newIDs)
        store.restore(Set(newIDs))
    }

    private func publish() {
        if publishesPolicy { ProtectionPolicy.publish(policy) }
    }

    private func save() {
        publish()
        guard let fileURL else { return }
        // Порядок стабильный, чтобы файл не переписывался по-разному при одном и том же списке.
        guard let data = try? JSONEncoder().encode(ids.sorted()) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func load(_ url: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(list)
    }

    private static var defaultFileURL: URL? {
        let manager = FileManager.default
        guard let base = try? manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        return base.appendingPathComponent("protected-assets.json")
    }
}

// MARK: - Группы умной чистки

extension AssetGroup {
    /// Что оставить в группе с учётом защиты.
    struct ProtectionPlan: Equatable {
        let bestID: String
        let keepIDs: Set<String>
    }

    /// Группа, где защищённые кадры всегда остаются. `nil`, если удалять в ней больше нечего.
    func protecting(_ policy: ProtectionPolicy, replacesBest: Bool) -> AssetGroup? {
        guard !policy.isEmpty else { return self }
        let protected = assets.filter { policy.protects($0) }.map(\.localIdentifier)
        guard !protected.isEmpty else { return self }
        guard let plan = Self.protectionPlan(
            ids: assets.map(\.localIdentifier), bestID: bestID, keepIDs: keepIDs,
            protected: protected, replacesBest: replacesBest
        ) else { return nil }
        // Если главным стал защищённый кадр, прежнее объяснение «почему лучший» к нему не относится.
        let reason = plan.bestID == bestID ? bestReason : nil
        return AssetGroup(assets: assets, bestID: plan.bestID, keepIDs: plan.keepIDs, reason: reason, id: id)
    }

    /// Защищённые кадры добавляются к тем, что остаются. Среди точных копий (`replacesBest`) защищённая копия
    /// становится той, что остаётся, вместо выбранной приложением, как и избранная: картинка у копий одна и та же.
    /// В похожих и сериях лучший кадр — другой снимок, поэтому он остаётся вместе с защищёнными.
    /// Если пользователь сам отметил несколько кадров серии, его отметки не снимаются.
    static func protectionPlan(
        ids: [String],
        bestID: String,
        keepIDs: Set<String>,
        protected: [String],
        replacesBest: Bool
    ) -> ProtectionPlan? {
        guard let first = protected.first else { return ProtectionPlan(bestID: bestID, keepIDs: keepIDs) }
        let protectedSet = Set(protected)
        var best = bestID
        var keep = keepIDs
        if replacesBest, !protectedSet.contains(bestID) {
            if keep == [bestID] { keep = [] }
            best = first
        }
        keep.formUnion(protectedSet)
        guard ids.contains(where: { !keep.contains($0) }) else { return nil }
        return ProtectionPlan(bestID: best, keepIDs: keep)
    }
}
