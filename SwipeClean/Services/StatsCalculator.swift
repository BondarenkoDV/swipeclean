import Foundation

/// Чистые функции для статистики, чтобы их можно было покрыть тестами.
enum StatsCalculator {
    struct Streak: Equatable {
        var current: Int
        var best: Int
    }

    /// Стрик — подряд идущие дни с хотя бы одним разобранным фото.
    /// Текущий стрик не обрывается, если сегодня ещё ничего не разобрано, но вчера было.
    static func streak(activeDays: Set<Date>, today: Date = .now, calendar: Calendar = .current) -> Streak {
        let days = Set(activeDays.map { calendar.startOfDay(for: $0) })
        guard !days.isEmpty else { return Streak(current: 0, best: 0) }

        let sorted = days.sorted()
        var best = 1
        var run = 1
        for (previous, day) in zip(sorted, sorted.dropFirst()) {
            if calendar.dateComponents([.day], from: previous, to: day).day == 1 {
                run += 1
                best = max(best, run)
            } else {
                run = 1
            }
        }

        let start = calendar.startOfDay(for: today)
        var cursor = days.contains(start) ? start : calendar.date(byAdding: .day, value: -1, to: start)!
        var current = 0
        while days.contains(cursor) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return Streak(current: current, best: max(best, current))
    }

    struct WeekPoint: Identifiable, Equatable {
        let weekStart: Date
        let reviewed: Int
        let trashed: Int
        var id: Date { weekStart }
    }

    /// Сумма по неделям за последние `weeks` недель, включая текущую.
    static func weekly(
        _ days: [(day: Date, reviewed: Int, trashed: Int)],
        weeks: Int = 8,
        today: Date = .now,
        calendar: Calendar = .current
    ) -> [WeekPoint] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start else { return [] }
        let starts = (0..<weeks).reversed().compactMap {
            calendar.date(byAdding: .weekOfYear, value: -$0, to: thisWeek)
        }
        var reviewed: [Date: Int] = [:]
        var trashed: [Date: Int] = [:]
        for entry in days {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: entry.day)?.start else { continue }
            reviewed[week, default: 0] += entry.reviewed
            trashed[week, default: 0] += entry.trashed
        }
        return starts.map { WeekPoint(weekStart: $0, reviewed: reviewed[$0] ?? 0, trashed: trashed[$0] ?? 0) }
    }
}
