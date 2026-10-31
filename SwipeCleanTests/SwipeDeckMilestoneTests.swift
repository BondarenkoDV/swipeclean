import XCTest
@testable import SwipeClean

@MainActor
final class SwipeDeckMilestoneTests: XCTestCase {
    private let mb: Int64 = 1024 * 1024
    private let gb: Int64 = 1024 * 1024 * 1024

    /// Вехи похвалы при свайпах в корзину: до первой вехи похвалы нет, дальше — наибольшая пройденная.
    func testMilestoneForBytes() {
        XCTAssertNil(SwipeDeckViewModel.milestone(for: 0))
        XCTAssertNil(SwipeDeckViewModel.milestone(for: 49 * mb))
        XCTAssertEqual(SwipeDeckViewModel.milestone(for: 50 * mb), 50 * mb)
        XCTAssertEqual(SwipeDeckViewModel.milestone(for: 300 * mb), 250 * mb)
        XCTAssertEqual(SwipeDeckViewModel.milestone(for: gb + mb), gb)
        XCTAssertEqual(SwipeDeckViewModel.milestone(for: 12 * gb), 10 * gb)
        // После 10 ГБ — каждые следующие 5 ГБ.
        XCTAssertEqual(SwipeDeckViewModel.milestone(for: 15 * gb + mb), 15 * gb)
        XCTAssertEqual(SwipeDeckViewModel.milestone(for: 21 * gb), 20 * gb)
    }
}
