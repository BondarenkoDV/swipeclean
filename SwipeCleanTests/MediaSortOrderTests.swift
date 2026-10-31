import XCTest
@testable import SwipeClean

final class MediaSortOrderTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func key(_ id: String, _ size: Int64, _ day: Int?) -> MediaSortOrder.Key {
        MediaSortOrder.Key(id: id, size: size, date: day.map { base.addingTimeInterval(Double($0) * 86_400) })
    }

    private func ids(_ order: MediaSortOrder, _ keys: [MediaSortOrder.Key]) -> [String] {
        order.sorted(keys) { $0 }.map(\.id)
    }

    private var sample: [MediaSortOrder.Key] {
        [key("small", 1_000, 3), key("huge", 900_000_000, 1), key("medium", 50_000_000, 2), key("big", 300_000_000, 4)]
    }

    func testLargestFirst() {
        XCTAssertEqual(ids(.largest, sample), ["huge", "big", "medium", "small"])
    }

    func testSmallestFirst() {
        XCTAssertEqual(ids(.smallest, sample), ["small", "medium", "big", "huge"])
    }

    func testNewestAndOldestFirst() {
        XCTAssertEqual(ids(.newest, sample), ["big", "small", "medium", "huge"])
        XCTAssertEqual(ids(.oldest, sample), ["huge", "medium", "small", "big"])
    }

    /// Одинаковые по размеру: новее — выше, а при той же дате порядок задаёт идентификатор и не прыгает.
    func testEqualSizesKeepStableOrder() {
        let keys = [key("b", 10, 1), key("c", 10, 2), key("a", 10, 1)]
        XCTAssertEqual(ids(.largest, keys), ["c", "a", "b"])
        XCTAssertEqual(ids(.smallest, keys), ["c", "a", "b"])
        XCTAssertEqual(ids(.largest, keys.reversed()), ["c", "a", "b"])
    }

    func testMissingDatesGoLast() {
        let keys = [key("undated", 5, nil), key("old", 5, 1), key("new", 5, 9)]
        XCTAssertEqual(ids(.newest, keys), ["new", "old", "undated"])
        XCTAssertEqual(ids(.oldest, keys), ["old", "new", "undated"])
        XCTAssertEqual(ids(.largest, keys), ["new", "old", "undated"])
    }

    func testRawValuesAreStableForSettings() {
        XCTAssertEqual(MediaSortOrder.allCases.map(\.rawValue), ["largest", "smallest", "newest", "oldest"])
        XCTAssertEqual(MediaSortOrder(rawValue: "largest"), .largest)
    }
}
