import XCTest
@testable import SwipeClean

final class SimilarChainTests: XCTestCase {
    private typealias Item = SmartCleanAnalyzer.SimilarItem

    private func item(_ id: String, seconds: TimeInterval) -> Item {
        Item(id: id, date: Date(timeIntervalSince1970: 1_700_000_000 + seconds))
    }

    private func distances(_ table: [String: Float]) -> (String, String) -> Float? {
        { a, b in table["\(a)-\(b)"] ?? table["\(b)-\(a)"] }
    }

    func testConsecutiveSimilarFramesFormOneChain() {
        let items = [item("a", seconds: 0), item("b", seconds: 5), item("c", seconds: 9)]
        let chains = SmartCleanAnalyzer.similarChains(items, distance: distances(["a-b": 0.2, "b-c": 0.3, "a-c": 0.35]))
        XCTAssertEqual(chains, [["a", "b", "c"]])
    }

    /// Панорама: сосед похож на соседа, но первый и последний кадр — разные сцены.
    func testChainDoesNotDriftAwayFromFirstFrame() {
        let items = [item("a", seconds: 0), item("b", seconds: 5), item("c", seconds: 9), item("d", seconds: 12)]
        let table: [String: Float] = ["a-b": 0.3, "b-c": 0.3, "a-c": 0.9, "c-d": 0.2]
        let chains = SmartCleanAnalyzer.similarChains(items, distance: distances(table))
        XCTAssertEqual(chains, [["a", "b"], ["c", "d"]])
    }

    func testTimeGapAndMissingPrintBreakChains() {
        let items = [item("a", seconds: 0), item("b", seconds: 5), item("c", seconds: 5 + 11 * 60), item("d", seconds: 5 + 11 * 60 + 3)]
        let chains = SmartCleanAnalyzer.similarChains(items, distance: distances(["a-b": 0.1, "b-c": 0.1, "c-d": 0.1]))
        XCTAssertEqual(chains, [["a", "b"], ["c", "d"]])

        let noPrint = SmartCleanAnalyzer.similarChains(items.prefix(2).map { $0 }, distance: { _, _ in nil })
        XCTAssertTrue(noPrint.isEmpty)
    }

    func testEveryChainIsReportedWhenClosed() {
        let items = [item("a", seconds: 0), item("b", seconds: 5), item("c", seconds: 60 * 60)]
        var closed: [[String]] = []
        _ = SmartCleanAnalyzer.similarChains(items, distance: distances(["a-b": 0.1]), chainEnded: { closed.append($0) })
        XCTAssertEqual(closed, [["a", "b"], ["c"]])
    }
}
