import Foundation

/// Месяц конкретного года; сравнивается по порядку во времени.
struct YearMonth: Hashable, Comparable {
    let year: Int
    let month: Int

    private var index: Int { year * 12 + month - 1 }

    static func < (lhs: YearMonth, rhs: YearMonth) -> Bool {
        lhs.index < rhs.index
    }
}

/// Период, за который умная чистка ищет фото: вся медиатека или диапазон месяцев.
/// Месяц, квартал и год — частные случаи диапазона, поэтому их можно объединять.
enum SmartCleanPeriod: Hashable {
    case all
    case months(from: YearMonth, through: YearMonth)

    static func month(year: Int, month: Int) -> SmartCleanPeriod {
        let value = YearMonth(year: year, month: month)
        return .months(from: value, through: value)
    }

    static func quarter(year: Int, quarter: Int) -> SmartCleanPeriod {
        .months(from: YearMonth(year: year, month: (quarter - 1) * 3 + 1), through: YearMonth(year: year, month: quarter * 3))
    }

    static func year(_ year: Int) -> SmartCleanPeriod {
        .months(from: YearMonth(year: year, month: 1), through: YearMonth(year: year, month: 12))
    }

    /// Наименьший диапазон, который покрывает оба периода.
    func spanning(_ other: SmartCleanPeriod) -> SmartCleanPeriod {
        guard case let .months(a, b) = self, case let .months(c, d) = other else { return .all }
        return .months(from: min(a, c), through: max(b, d))
    }

    /// Лежит ли `other` целиком внутри этого периода.
    func contains(_ other: SmartCleanPeriod) -> Bool {
        switch (self, other) {
        case (.all, _): true
        case (.months, .all): false
        case let (.months(a, b), .months(c, d)): a <= c && d <= b
        }
    }

    var title: String {
        guard case let .months(from, through) = self else { return String(localized: "Всё время") }
        if from == through {
            return LibrarySource.monthTitle(year: from.year, month: from.month)
        }
        if from.year == through.year {
            if from.month == 1, through.month == 12 {
                return String(localized: "\(String(from.year)) год")
            }
            if (from.month - 1) % 3 == 0, through.month == from.month + 2 {
                return String(localized: "\((from.month - 1) / 3 + 1)-й квартал \(String(from.year))")
            }
        }
        return "\(Self.shortTitle(from)) – \(Self.shortTitle(through))"
    }

    /// Интервал дат для фильтра. `nil` — без ограничения.
    func interval(calendar: Calendar = .current) -> DateInterval? {
        guard case let .months(from, through) = self,
              let start = calendar.date(from: DateComponents(year: from.year, month: from.month, day: 1)),
              let last = calendar.date(from: DateComponents(year: through.year, month: through.month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: last)
        else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// Начинается ли период позже `date`: такие ячейки в календаре недоступны.
    func isFuture(after date: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let start = interval(calendar: calendar)?.start else { return false }
        return start > date
    }

    private static func shortTitle(_ value: YearMonth) -> String {
        let date = Calendar.current.date(from: DateComponents(year: value.year, month: value.month, day: 1)) ?? .now
        return date.formatted(.dateTime.month(.abbreviated).year())
    }
}

/// Хранение в UserDefaults строкой: `all` или `r-2026-1-2026-3`.
extension SmartCleanPeriod: RawRepresentable {
    init?(rawValue: String) {
        if rawValue == "all" {
            self = .all
            return
        }
        let parts = rawValue.split(separator: "-").map(String.init)
        guard parts.count == 5, parts[0] == "r" else { return nil }
        let numbers = parts.dropFirst().compactMap { Int($0) }
        guard numbers.count == 4,
              (1...12).contains(numbers[1]), (1...12).contains(numbers[3])
        else { return nil }
        let from = YearMonth(year: numbers[0], month: numbers[1])
        let through = YearMonth(year: numbers[2], month: numbers[3])
        guard from <= through else { return nil }
        self = .months(from: from, through: through)
    }

    var rawValue: String {
        switch self {
        case .all: "all"
        case let .months(from, through): "r-\(from.year)-\(from.month)-\(through.year)-\(through.month)"
        }
    }
}
