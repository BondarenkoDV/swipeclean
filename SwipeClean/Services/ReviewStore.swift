import Foundation
import Photos
import SwiftData

/// Сохраняет решения и отдаёт множество уже разобранных ассетов.
@MainActor
@Observable
final class ReviewStore {
    /// Решение по одному ассету для пакетной записи.
    struct Decision {
        let localIdentifier: String
        let decision: SwipeDecision
        /// Размер считается только для новых записей: запрос ресурсов PhotoKit не бесплатный.
        let fileSize: () -> Int64

        init(localIdentifier: String, decision: SwipeDecision, fileSize: @escaping () -> Int64) {
            self.localIdentifier = localIdentifier
            self.decision = decision
            self.fileSize = fileSize
        }

        init(_ asset: PHAsset, _ decision: SwipeDecision) {
            self.init(localIdentifier: asset.localIdentifier, decision: decision, fileSize: { asset.fileSize ?? 0 })
        }
    }

    private let context: ModelContext
    private(set) var reviewedIDs: Set<String> = []
    private(set) var trashCount = 0
    /// Сегодня уже чистили: от этого зависят серия и сегодняшнее напоминание.
    private(set) var isActiveToday = false

    init(context: ModelContext) {
        self.context = context
        reload()
    }

    func reload() {
        let all = (try? context.fetch(FetchDescriptor<ReviewedAsset>())) ?? []
        // «Позже» не считается разобранным: такие фото снова попадут в подборки.
        reviewedIDs = Set(all.filter { $0.decision != .later }.map(\.localIdentifier))
        trashCount = all.filter { $0.decision == .trash }.count
        refreshActivity()
    }

    /// Пересчитывает, чистили ли сегодня. Вызывается после изменений и при возврате в приложение: день мог смениться.
    func refreshActivity() {
        let day = Calendar.current.startOfDay(for: .now)
        var descriptor = FetchDescriptor<DailyStat>(predicate: #Predicate { $0.day == day })
        descriptor.fetchLimit = 1
        let active = (try? context.fetch(descriptor).first)?.isActive ?? false
        if active != isActiveToday { isActiveToday = active }
    }

    /// Дни, засчитанные в серию.
    func activeDays() -> Set<Date> {
        let descriptor = FetchDescriptor<DailyStat>(predicate: #Predicate { $0.reviewed > 0 || $0.trashed > 0 })
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.day))
    }

    func streak(today: Date = .now) -> StatsCalculator.Streak {
        StatsCalculator.streak(activeDays: activeDays(), today: today)
    }

    func record(_ asset: PHAsset, decision: SwipeDecision) {
        record([Decision(asset, decision)])
    }

    /// Записывает решения пакетом: один запрос к хранилищу и одно сохранение вместо N.
    func record(_ decisions: [Decision]) {
        guard !decisions.isEmpty else { return }
        let ids = decisions.map(\.localIdentifier)
        let descriptor = FetchDescriptor<ReviewedAsset>(predicate: #Predicate { ids.contains($0.localIdentifier) })
        var items = Dictionary(
            ((try? context.fetch(descriptor)) ?? []).map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let stat = today()
        var reviewed = reviewedIDs
        var trash = trashCount
        for entry in decisions {
            let id = entry.localIdentifier
            if let item = items[id] {
                if item.decision == .trash { trash -= 1 }
                // Повторное решение по уже разобранному фото не считается новым разбором,
                // как и повторное «позже» в подборке «Решу позже».
                if item.decision == .later, entry.decision != .later { stat.reviewed += 1 }
                item.decision = entry.decision
                item.decidedAt = .now
            } else {
                let item = ReviewedAsset(localIdentifier: id, decision: entry.decision, fileSize: entry.fileSize())
                context.insert(item)
                items[id] = item
                stat.reviewed += 1
            }
            if entry.decision == .trash { trash += 1 }
            if entry.decision == .later {
                reviewed.remove(id)
            } else {
                reviewed.insert(id)
            }
        }
        reviewedIDs = reviewed
        trashCount = trash
        save()
        refreshActivity()
    }

    func undo(_ asset: PHAsset, restoring previous: SwipeDecision? = nil) {
        undo(id: asset.localIdentifier, restoring: previous)
    }

    /// Отменяет решение. Если до него у фото уже было решение (например, «позже»),
    /// оно возвращается, а не удаляется вместе с записью.
    func undo(id: String, restoring previous: SwipeDecision? = nil) {
        let stat = today()
        guard let existing = item(for: id) else {
            reviewedIDs.remove(id)
            stat.reviewed = max(0, stat.reviewed - 1)
            save()
            refreshActivity()
            return
        }
        if existing.decision == .trash { trashCount -= 1 }
        if let previous {
            // Разбор «позже» засчитывался как новый, значит его и откатываем.
            if previous == .later, existing.decision != .later {
                stat.reviewed = max(0, stat.reviewed - 1)
            }
            existing.decision = previous
            if previous == .trash { trashCount += 1 }
            if previous == .later {
                reviewedIDs.remove(id)
            } else {
                reviewedIDs.insert(id)
            }
        } else {
            context.delete(existing)
            reviewedIDs.remove(id)
            stat.reviewed = max(0, stat.reviewed - 1)
        }
        save()
        refreshActivity()
    }

    func laterIDs() -> [String] {
        let later = SwipeDecision.later.rawValue
        let descriptor = FetchDescriptor<ReviewedAsset>(predicate: #Predicate { $0.decisionRaw == later })
        return ((try? context.fetch(descriptor)) ?? []).map(\.localIdentifier)
    }

    /// Сколько записей с таким решением. Считает в хранилище, не загружая объекты в память.
    func count(of decision: SwipeDecision, excludingDeleted: Bool = false) -> Int {
        let raw = decision.rawValue
        let predicate: Predicate<ReviewedAsset>
        if excludingDeleted {
            predicate = #Predicate<ReviewedAsset> { $0.decisionRaw == raw && $0.wasDeleted == false }
        } else {
            predicate = #Predicate<ReviewedAsset> { $0.decisionRaw == raw }
        }
        return (try? context.fetchCount(FetchDescriptor<ReviewedAsset>(predicate: predicate))) ?? 0
    }

    // MARK: - Корзина

    func trashItems() -> [ReviewedAsset] {
        let trash = SwipeDecision.trash.rawValue
        let descriptor = FetchDescriptor<ReviewedAsset>(
            predicate: #Predicate { $0.decisionRaw == trash },
            sortBy: [SortDescriptor(\.decidedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Возвращает фото из корзины: они считаются оставленными.
    func restore(_ ids: Set<String>) {
        for item in trashItems() where ids.contains(item.localIdentifier) {
            item.decision = .keep
        }
        save()
        reload()
    }

    /// Фото из корзины, которых уже нет в медиатеке (удалены в другом приложении).
    func forgetMissing(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for item in trashItems() where ids.contains(item.localIdentifier) {
            item.decision = .keep
            item.wasDeleted = true
        }
        save()
        reload()
    }

    /// Удаляет фото из медиатеки одним системным подтверждением.
    /// Возвращает количество освобождённых байт.
    @discardableResult
    func deleteFromLibrary(_ ids: Set<String>) async throws -> Int64 {
        let targetIDs = trashItems().map(\.localIdentifier).filter { ids.contains($0) }
        guard !targetIDs.isEmpty else { return 0 }
        let deleted = try await LibraryEditor.deleteAssets(withIDs: targetIDs)

        // Пока шло системное подтверждение, хранилище могли поменять, поэтому записи читаются заново.
        // Записи остаются, чтобы фото не всплывали снова, если пользователь восстановит их из «Недавно удалённых».
        // В статистику идут только фото, которые действительно удалены сейчас, а не раньше в другом приложении.
        let items = trashItems().filter { ids.contains($0.localIdentifier) }
        let freed = items.filter { deleted.contains($0.localIdentifier) }
        let bytes = freed.reduce(Int64(0)) { $0 + $1.fileSize }
        let stat = today()
        stat.trashed += freed.count
        stat.bytesFreed += bytes
        for item in items {
            item.decision = .keep
            item.wasDeleted = true
        }
        save()
        reload()
        return bytes
    }

    func isReviewed(_ asset: PHAsset) -> Bool {
        reviewedIDs.contains(asset.localIdentifier)
    }

    /// Переносит решения со старых фото на их замену (Live Photo стало обычным фото): оставленное
    /// не всплывает в разборе заново, а отложенное и отправленное в корзину остаётся там же.
    /// `sizes` — размеры новых фото по их идентификаторам, чтобы корзина считала освобождаемое верно.
    func transfer(_ ids: [String: String], sizes: [String: Int64] = [:]) {
        guard !ids.isEmpty else { return }
        let old = Array(ids.keys)
        let descriptor = FetchDescriptor<ReviewedAsset>(predicate: #Predicate { old.contains($0.localIdentifier) })
        guard let items = try? context.fetch(descriptor), !items.isEmpty else { return }
        for item in items {
            guard let new = ids[item.localIdentifier] else { continue }
            item.localIdentifier = new
            if let size = sizes[new] { item.fileSize = size }
        }
        save()
        reload()
    }

    /// Объекты удаляются по одному, а не пакетно через `delete(model:)`: пакетное удаление идёт мимо контекста,
    /// и открытые экраны (статистика с @Query) держали бы уже удалённые записи, обращение к которым роняет SwiftData.
    func resetProgress() {
        for item in (try? context.fetch(FetchDescriptor<ReviewedAsset>())) ?? [] {
            context.delete(item)
        }
        for stat in (try? context.fetch(FetchDescriptor<DailyStat>())) ?? [] {
            context.delete(stat)
        }
        save()
        reload()
    }

    func item(for id: String) -> ReviewedAsset? {
        var descriptor = FetchDescriptor<ReviewedAsset>(predicate: #Predicate { $0.localIdentifier == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func today() -> DailyStat {
        let day = Calendar.current.startOfDay(for: .now)
        var descriptor = FetchDescriptor<DailyStat>(predicate: #Predicate { $0.day == day })
        descriptor.fetchLimit = 1
        if let stat = try? context.fetch(descriptor).first { return stat }
        let stat = DailyStat(day: day)
        context.insert(stat)
        return stat
    }

    func save() {
        try? context.save()
    }

    #if DEBUG
    /// Для UI-тестов: серия из `days` прошлых дней, а сегодня ещё не чистили.
    func seedStreak(days: Int) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        for offset in 1...max(days, 1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: start) else { continue }
            let stat = DailyStat(day: calendar.startOfDay(for: day))
            stat.reviewed = 5
            context.insert(stat)
        }
        save()
        refreshActivity()
    }
    #endif
}
