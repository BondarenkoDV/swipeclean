import XCTest
@testable import SwipeClean

final class LibrarySourceTests: XCTestCase {
    func testIdentifiersAreUnique() {
        let sources = LibrarySource.featured + [.later, .month(year: 2025, month: 1), .month(year: 2025, month: 2), .album(id: "a", title: "A")]
        XCTAssertEqual(Set(sources.map(\.id)).count, sources.count)
    }

    func testMonthTitleIsNotEmpty() {
        XCTAssertFalse(LibrarySource.monthTitle(year: 2024, month: 3).isEmpty)
    }

    func testDecisionRawValuesRoundTrip() {
        for decision in SwipeDecision.allCases {
            XCTAssertEqual(SwipeDecision(rawValue: decision.rawValue), decision)
        }
    }
}
