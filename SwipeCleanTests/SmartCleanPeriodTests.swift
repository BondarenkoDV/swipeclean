import XCTest
@testable import SwipeClean

final class SmartCleanPeriodTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testAllTimeHasNoLimit() {
        XCTAssertNil(SmartCleanPeriod.all.interval(calendar: calendar))
    }

    func testMonthCoversWholeMonth() {
        let interval = SmartCleanPeriod.month(year: 2026, month: 2).interval(calendar: calendar)
        XCTAssertEqual(interval?.start, date(2026, 2))
        XCTAssertEqual(interval?.end, date(2026, 3))
    }

    func testQuarterAndYearSpans() {
        let quarter = SmartCleanPeriod.quarter(year: 2025, quarter: 4).interval(calendar: calendar)
        XCTAssertEqual(quarter?.start, date(2025, 10))
        XCTAssertEqual(quarter?.end, date(2026, 1))
        let year = SmartCleanPeriod.year(2024).interval(calendar: calendar)
        XCTAssertEqual(year?.start, date(2024, 1))
        XCTAssertEqual(year?.end, date(2025, 1))
    }

    func testRawValueRoundTrip() {
        let periods: [SmartCleanPeriod] = [.all, .month(year: 2026, month: 10), .quarter(year: 2026, quarter: 2), .year(2023),
                                           .month(year: 2025, month: 11).spanning(.month(year: 2026, month: 2))]
        for period in periods {
            XCTAssertEqual(SmartCleanPeriod(rawValue: period.rawValue), period)
        }
        XCTAssertNil(SmartCleanPeriod(rawValue: "month"))
        XCTAssertNil(SmartCleanPeriod(rawValue: "r-2026-13-2026-1"))
        XCTAssertNil(SmartCleanPeriod(rawValue: "r-2026-5-2026-1"))
    }

    func testRangeSpansInAnyOrder() {
        let range = SmartCleanPeriod.month(year: 2026, month: 5).spanning(.month(year: 2025, month: 11))
        XCTAssertEqual(range, .months(from: YearMonth(year: 2025, month: 11), through: YearMonth(year: 2026, month: 5)))
        XCTAssertEqual(range.interval(calendar: calendar)?.start, date(2025, 11))
        XCTAssertEqual(range.interval(calendar: calendar)?.end, date(2026, 6))
        XCTAssertTrue(range.contains(.month(year: 2026, month: 1)))
        XCTAssertFalse(range.contains(.month(year: 2026, month: 6)))
        XCTAssertEqual(SmartCleanPeriod.quarter(year: 2026, quarter: 1).spanning(.quarter(year: 2026, quarter: 4)), .year(2026))
    }

    func testFuturePeriodsAreDetected() {
        let now = date(2026, 10, 27)
        XCTAssertTrue(SmartCleanPeriod.month(year: 2026, month: 11).isFuture(after: now, calendar: calendar))
        XCTAssertFalse(SmartCleanPeriod.month(year: 2026, month: 10).isFuture(after: now, calendar: calendar))
        XCTAssertFalse(SmartCleanPeriod.all.isFuture(after: now, calendar: calendar))
    }
}
