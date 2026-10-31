import Foundation
import SwiftUI

/// Порядок фото и видео в сетках с размерами: по размеру файла или по дате съёмки.
/// Выбор запоминается и общий для всех таких сеток.
enum MediaSortOrder: String, CaseIterable, Identifiable, Sendable {
    case largest
    case smallest
    case newest
    case oldest

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .largest: "Сначала большие"
        case .smallest: "Сначала маленькие"
        case .newest: "Сначала новые"
        case .oldest: "Сначала старые"
        }
    }

    /// Ключ одного элемента: размер и дата считаются один раз, а не при каждом сравнении.
    struct Key: Sendable {
        let id: String
        let size: Int64
        let date: Date?
    }

    /// Сортирует по выбранному порядку. При равных размерах или датах новые идут первыми,
    /// а дальше решает идентификатор, чтобы клетки не менялись местами между пересчётами.
    func sorted<Item>(_ items: [Item], key: (Item) -> Key) -> [Item] {
        items
            .map { (item: $0, key: key($0)) }
            .sorted { precedes($0.key, $1.key) }
            .map(\.item)
    }

    func precedes(_ a: Key, _ b: Key) -> Bool {
        switch self {
        case .largest where a.size != b.size: return a.size > b.size
        case .smallest where a.size != b.size: return a.size < b.size
        case .oldest where a.date != b.date: return Self.isEarlier(a.date, b.date)
        default: break
        }
        if a.date != b.date { return Self.isLater(a.date, b.date) }
        return a.id < b.id
    }

    /// Фото без даты в любом порядке по дате идут последними.
    private static func isLater(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case let (a?, b?): a > b
        case (.some, nil): true
        default: false
        }
    }

    private static func isEarlier(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case let (a?, b?): a < b
        case (.some, nil): true
        default: false
        }
    }
}

/// Кнопка сортировки в панели навигации: меню с порядками, выбранный отмечен галочкой.
struct MediaSortMenu: View {
    @Binding var order: MediaSortOrder

    var body: some View {
        Menu {
            Picker("Сортировка", selection: $order) {
                ForEach(MediaSortOrder.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            Label("Сортировка", systemImage: "arrow.up.arrow.down")
        }
    }
}
