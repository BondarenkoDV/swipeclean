import XCTest
@testable import SwipeClean

final class StatsCalculatorTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func day(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)!
    }

    func testEmptyStreak() {
        let streak = StatsCalculator.streak(activeDays: [], today: day("2026-10-27"), calendar: calendar)
        XCTAssertEqual(streak, .init(current: 0, best: 0))
    }

    func testCurrentStreakIncludesToday() {
        let days: Set<Date> = [day("2026-10-25"), day("2026-10-26"), day("2026-10-27")]
        let streak = StatsCalculator.streak(activeDays: days, today: day("2026-10-27"), calendar: calendar)
        XCTAssertEqual(streak, .init(current: 3, best: 3))
    }

    func testStreakSurvivesUntilEndOfToday() {
        let days: Set<Date> = [day("2026-10-25"), day("2026-10-26")]
        let streak = StatsCalculator.streak(activeDays: days, today: day("2026-10-27"), calendar: calendar)
        XCTAssertEqual(streak.current, 2)
    }

    func testStreakBreaksAfterMissedDay() {
        let days: Set<Date> = [day("2026-10-20"), day("2026-10-21"), day("2026-10-22"), day("2026-10-25")]
        let streak = StatsCalculator.streak(activeDays: days, today: day("2026-10-27"), calendar: calendar)
        XCTAssertEqual(streak, .init(current: 0, best: 3))
    }

    func testDuplicateTimesInOneDayCountOnce() {
        let morning = day("2026-10-27").addingTimeInterval(3600)
        let evening = day("2026-10-27").addingTimeInterval(20 * 3600)
        let streak = StatsCalculator.streak(activeDays: [morning, evening], today: day("2026-10-27"), calendar: calendar)
        XCTAssertEqual(streak, .init(current: 1, best: 1))
    }

    func testWeeklyAggregation() {
        let entries: [(day: Date, reviewed: Int, trashed: Int)] = [
            (day("2026-10-26"), 10, 4), // понедельник текущей недели
            (day("2026-10-27"), 5, 1),
            (day("2026-10-20"), 7, 2), // прошлая неделя
            (day("2026-01-01"), 99, 99), // за пределами окна
        ]
        let weeks = StatsCalculator.weekly(entries, weeks: 3, today: day("2026-10-27"), calendar: calendar)
        XCTAssertEqual(weeks.map(\.reviewed), [0, 7, 15])
        XCTAssertEqual(weeks.map(\.trashed), [0, 2, 5])
        XCTAssertEqual(weeks.last?.weekStart, day("2026-10-26"))
    }

    func testRecentDaysMarkActiveDaysAndToday() {
        let marks = StatsCalculator.recentDays(
            3, activeDays: [day("2026-10-25"), day("2026-10-27"), day("2026-10-20")], today: day("2026-10-27"), calendar: calendar
        )
        XCTAssertEqual(marks.map(\.day), [day("2026-10-25"), day("2026-10-26"), day("2026-10-27")])
        XCTAssertEqual(marks.map(\.isActive), [true, false, true])
        XCTAssertEqual(marks.map(\.isToday), [false, false, true])
    }
}
