import EventKit
import Foundation

/// Прошедшее событие календаря в виде простых значений.
struct PastEvent: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String
    /// Цвет календаря в RGB, чтобы строка выглядела как в приложении «Календарь».
    let color: [Double]
}

/// Насколько старые события показывать.
enum EventAge: String, CaseIterable, Identifiable {
    case month
    case halfYear
    case year
    case threeYears

    var id: String { rawValue }

    var title: String {
        switch self {
        case .month: String(localized: "Старше месяца")
        case .halfYear: String(localized: "Старше полугода")
        case .year: String(localized: "Старше года")
        case .threeYears: String(localized: "Старше 3 лет")
        }
    }

    var cutoff: Date {
        let calendar = Calendar.current
        return switch self {
        case .month: calendar.date(byAdding: .month, value: -1, to: .now) ?? .now
        case .halfYear: calendar.date(byAdding: .month, value: -6, to: .now) ?? .now
        case .year: calendar.date(byAdding: .year, value: -1, to: .now) ?? .now
        case .threeYears: calendar.date(byAdding: .year, value: -3, to: .now) ?? .now
        }
    }
}

/// Старые события календаря. Повторяющиеся не трогаем: удаление одного прошлого повтора
/// создаёт исключение в серии, а удаление всей серии убрало бы и будущие встречи.
@MainActor
@Observable
final class CalendarCleaner {
    enum Access {
        case unknown
        case granted
        case denied
    }

    private(set) var access: Access
    private(set) var isLoading = false
    private(set) var events: [PastEvent] = []

    init() {
        access = Self.currentAccess()
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .unknown
        default: .denied
        }
    }

    func requestAccessAndLoad(age: EventAge) async {
        if access == .unknown {
            let granted = (try? await EKEventStore().requestFullAccessToEvents()) ?? false
            access = granted ? .granted : Self.currentAccess()
        }
        guard access == .granted else { return }
        if SwipeCleanApp.isUITesting, ProcessInfo.processInfo.arguments.contains("-seedCalendar") {
            await Task.detached { CalendarStoreWork.seedTestEvents() }.value
        }
        await reload(age: age)
    }

    func reload(age: EventAge) async {
        isLoading = true
        let cutoff = age.cutoff
        events = await Task.detached(priority: .userInitiated) { CalendarStoreWork.pastEvents(before: cutoff) }.value
        isLoading = false
    }

    func delete(_ ids: Set<String>, age: EventAge) async throws {
        let ids = Array(ids)
        try await Task.detached(priority: .userInitiated) { try CalendarStoreWork.delete(ids) }.value
        await reload(age: age)
    }
}

/// Работа с EKEventStore вне главного потока; между задачами передаются только идентификаторы.
enum CalendarStoreWork {
    /// EventKit ищет не больше чем за четыре года за раз, поэтому идём назад окнами.
    private static let window: TimeInterval = 4 * 365 * 24 * 3600
    private static let oldest = Date(timeIntervalSince1970: 946_684_800) // 2000 год

    static func pastEvents(before cutoff: Date) -> [PastEvent] {
        let store = EKEventStore()
        let calendars = store.calendars(for: .event).filter { $0.allowsContentModifications && $0.type != .birthday }
        guard !calendars.isEmpty else { return [] }
        var seen = Set<String>()
        var events: [PastEvent] = []
        var end = cutoff
        while end > oldest {
            let start = max(end.addingTimeInterval(-window), oldest)
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
            for event in store.events(matching: predicate) {
                guard !event.hasRecurrenceRules, event.endDate <= cutoff,
                      let id = event.eventIdentifier, seen.insert(id).inserted else { continue }
                let srgb = CGColorSpace(name: CGColorSpace.sRGB)
                let color = srgb.flatMap { event.calendar.cgColor?.converted(to: $0, intent: .defaultIntent, options: nil) }?.components ?? []
                let title = event.title ?? ""
                events.append(PastEvent(
                    id: id,
                    title: title.isEmpty ? String(localized: "Без названия") : title,
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarTitle: event.calendar.title,
                    color: color.prefix(3).map(Double.init)
                ))
            }
            end = start
        }
        return events.sorted { $0.start > $1.start }
    }

    static func delete(_ ids: [String]) throws {
        let store = EKEventStore()
        for id in ids {
            guard let event = store.event(withIdentifier: id) else { continue }
            try store.remove(event, span: .thisEvent, commit: false)
        }
        try store.commit()
    }

    /// Только для UI-тестов на симуляторе: три старых события, если их ещё нет.
    static func seedTestEvents() {
        let store = EKEventStore()
        guard let calendar = store.defaultCalendarForNewEvents else { return }
        let twoYearsAgo = Calendar.current.date(byAdding: .year, value: -2, to: .now) ?? .now
        let existing = store.events(matching: store.predicateForEvents(
            withStart: twoYearsAgo.addingTimeInterval(-7 * 86_400),
            end: twoYearsAgo.addingTimeInterval(7 * 86_400),
            calendars: [calendar]
        ))
        guard !existing.contains(where: { $0.title?.hasPrefix("Тест событие") == true }) else { return }
        for day in 0..<3 {
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = "Тест событие \(day + 1)"
            event.startDate = twoYearsAgo.addingTimeInterval(Double(day) * 86_400)
            event.endDate = event.startDate.addingTimeInterval(3600)
            try? store.save(event, span: .thisEvent, commit: false)
        }
        try? store.commit()
    }
}
