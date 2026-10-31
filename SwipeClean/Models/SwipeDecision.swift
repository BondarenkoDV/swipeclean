import Foundation

enum SwipeDecision: String, Codable, CaseIterable, Sendable {
    case trash
    case keep
    case favorite
    case later

    var title: String {
        switch self {
        case .trash: String(localized: "УДАЛИТЬ")
        case .keep: String(localized: "ОСТАВИТЬ")
        case .favorite: String(localized: "В ИЗБРАННОЕ")
        case .later: String(localized: "ПОЗЖЕ")
        }
    }

    /// Короткая подпись для значков при свайпе.
    var label: String {
        switch self {
        case .trash: String(localized: "Удалить")
        case .keep: String(localized: "Оставить")
        case .favorite: String(localized: "В избранное")
        case .later: String(localized: "Позже")
        }
    }

    var symbol: String {
        switch self {
        case .trash: "trash.fill"
        case .keep: "checkmark"
        case .favorite: "heart.fill"
        case .later: "clock.fill"
        }
    }
}
