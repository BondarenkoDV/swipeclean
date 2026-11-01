import Foundation
import SwiftData

/// Решение пользователя по одному ассету. Записи с решением `.trash` — это содержимое корзины.
@Model
final class ReviewedAsset {
    @Attribute(.unique) var localIdentifier: String
    var decisionRaw: String
    var decidedAt: Date
    var fileSize: Int64
    /// Фото удалено из медиатеки через корзину приложения.
    var wasDeleted: Bool = false

    init(localIdentifier: String, decision: SwipeDecision, fileSize: Int64) {
        self.localIdentifier = localIdentifier
        self.decisionRaw = decision.rawValue
        self.decidedAt = .now
        self.fileSize = fileSize
    }

    var decision: SwipeDecision {
        get { SwipeDecision(rawValue: decisionRaw) ?? .keep }
        set { decisionRaw = newValue.rawValue }
    }
}

/// Счётчики за день для статистики и стриков.
@Model
final class DailyStat {
    @Attribute(.unique) var day: Date
    var reviewed: Int
    var trashed: Int
    var bytesFreed: Int64

    init(day: Date) {
        self.day = day
        self.reviewed = 0
        self.trashed = 0
        self.bytesFreed = 0
    }

    /// День идёт в серию, если в нём разобрано или удалено хотя бы одно фото.
    var isActive: Bool { reviewed > 0 || trashed > 0 }
}
