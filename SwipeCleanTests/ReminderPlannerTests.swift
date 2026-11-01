import XCTest
@testable import SwipeClean

/// План ежедневных напоминаний: когда они срабатывают и о чём пишут.
final class ReminderPlannerTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    private let evening = 20 * 60

    func testFirstReminderIsTodayBeforeItsTime() {
        let dates = ReminderPlanner.fireDates(
            now: date("2026-10-31T09:00:00Z"), minutes: evening, activeToday: false, days: 3, calendar: calendar
        )
        XCTAssertEqual(dates, [date("2026-10-31T20:00:00Z"), date("2026-11-01T20:00:00Z"), date("2026-11-02T20:00:00Z")])
    }

    func testTodayIsSkippedAfterCleaning() {
        let dates = ReminderPlanner.fireDates(
            now: date("2026-10-31T09:00:00Z"), minutes: evening, activeToday: true, days: 3, calendar: calendar
        )
        XCTAssertEqual(dates, [date("2026-11-01T20:00:00Z"), date("2026-11-02T20:00:00Z")])
    }

    func testTodayIsSkippedWhenTimeHasPassed() {
        let dates = ReminderPlanner.fireDates(
            now: date("2026-10-31T21:30:00Z"), minutes: 9 * 60 + 15, activeToday: false, days: 2, calendar: calendar
        )
        XCTAssertEqual(dates, [date("2026-11-01T09:15:00Z")])
    }

    func testDefaultHorizonCoversTwoWeeks() {
        let dates = ReminderPlanner.fireDates(now: date("2026-10-31T09:00:00Z"), minutes: evening, activeToday: false, calendar: calendar)
        XCTAssertEqual(dates.count, ReminderPlanner.horizon)
        XCTAssertEqual(Set(dates).count, dates.count)
    }

    func testStreakAtRiskTodayWhenNotCleanedYet() {
        let kind = ReminderPlanner.kind(
            for: date("2026-10-31T20:00:00Z"), now: date("2026-10-31T09:00:00Z"),
            activeToday: false, streak: 4, onThisDay: 0, calendar: calendar
        )
        XCTAssertEqual(kind, .streak(4))
    }

    func testTomorrowMentionsStreakAfterCleaningToday() {
        let kind = ReminderPlanner.kind(
            for: date("2026-11-01T20:00:00Z"), now: date("2026-10-31T09:00:00Z"),
            activeToday: true, streak: 5, onThisDay: 0, calendar: calendar
        )
        XCTAssertEqual(kind, .streak(5))
    }

    /// Если сегодня не почистить, к завтрашнему вечеру серии уже не будет: о ней не пишем.
    func testTomorrowForgetsStreakWithoutCleaningToday() {
        let kind = ReminderPlanner.kind(
            for: date("2026-11-01T20:00:00Z"), now: date("2026-10-31T09:00:00Z"),
            activeToday: false, streak: 5, onThisDay: 0, calendar: calendar
        )
        guard case .generic = kind else { return XCTFail("Ожидалось обычное напоминание, а не \(kind)") }
    }

    func testOnThisDayWinsAndKeepsStreak() {
        let kind = ReminderPlanner.kind(
            for: date("2026-10-31T20:00:00Z"), now: date("2026-10-31T09:00:00Z"),
            activeToday: false, streak: 4, onThisDay: 23, calendar: calendar
        )
        XCTAssertEqual(kind, .onThisDay(count: 23, streak: 4))
        XCTAssertEqual(kind.source, ReminderPlanner.Kind.onThisDaySource)
        XCTAssertTrue(kind.title.contains("23"), kind.title)
        XCTAssertTrue(kind.body.contains("4"), kind.body)
    }

    func testLaterDaysAreGenericAndRotate() {
        let now = date("2026-10-31T09:00:00Z")
        let kinds = ["2026-11-02T20:00:00Z", "2026-11-03T20:00:00Z", "2026-11-04T20:00:00Z"].map {
            ReminderPlanner.kind(for: date($0), now: now, activeToday: true, streak: 7, onThisDay: 0, calendar: calendar)
        }
        let variants = kinds.compactMap { kind -> Int? in
            if case let .generic(variant) = kind { return variant }
            return nil
        }
        XCTAssertEqual(variants.count, 3, "\(kinds)")
        XCTAssertEqual(Set(variants).count, 3, "Три дня подряд — три разных текста")
        XCTAssertEqual(Set(kinds.map(\.title)).count, 3)
        XCTAssertTrue(kinds.allSatisfy { $0.source == ReminderPlanner.Kind.reviewSource })
    }

    /// По одному напоминанию на день: идентификаторы не повторяются, иначе система заменила бы одно другим.
    func testPlannedRemindersHaveOneIDPerDay() {
        let dates = ReminderPlanner.fireDates(now: date("2026-10-31T09:00:00Z"), minutes: evening, activeToday: false, days: 5, calendar: calendar)
        let planned = DailyReminder.plan(
            dates: dates, now: date("2026-10-31T09:00:00Z"), activeToday: false, streak: 2, reviewed: [], calendar: calendar
        )
        XCTAssertEqual(planned.map(\.date), dates)
        XCTAssertEqual(Set(planned.map(\.id)).count, dates.count)
        XCTAssertTrue(planned.allSatisfy { $0.id.hasPrefix(DailyReminder.identifierPrefix) && !$0.title.isEmpty && !$0.body.isEmpty })
        XCTAssertTrue(DailyReminder.plan(dates: [], now: .now, activeToday: false, streak: 0, reviewed: []).isEmpty)
    }
}
