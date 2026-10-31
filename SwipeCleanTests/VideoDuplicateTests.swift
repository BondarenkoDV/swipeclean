import XCTest
@testable import SwipeClean

final class VideoDuplicateTests: XCTestCase {
    private typealias Item = SmartCleanAnalyzer.VideoItem

    private static let poster: [UInt8] = (0..<(64 * 64)).map { (index: Int) -> UInt8 in
        UInt8(index % 64 * 3 + index / 64)
    }
    private static let samePoster: @Sendable (String) -> [UInt8]? = { _ in poster }

    func testSameDurationAndFrameAreGrouped() {
        let items = [
            Item(id: "a", duration: 30.2, hash: 0b1010_1010),
            Item(id: "b", duration: 30.8, hash: 0b1010_1011),
            Item(id: "c", duration: 12, hash: 0b1010_1010),
        ]
        XCTAssertEqual(SmartCleanAnalyzer.videoDuplicateClusters(items, pixels: Self.samePoster).map(Set.init), [["a", "b"]])
    }

    /// Два дубля одной сцены с похожей обложкой, но другим кадром — не копии.
    func testPosterMustMatchPixelByPixel() {
        let items = [
            Item(id: "a", duration: 20, hash: 0b1010_1010),
            Item(id: "b", duration: 20.3, hash: 0b1010_1010),
        ]
        let shifted = Self.poster.enumerated().map { index, value in index % 64 < 16 && index / 64 < 16 ? value &+ 90 : value }
        XCTAssertTrue(SmartCleanAnalyzer.videoDuplicateClusters(items, pixels: { $0 == "a" ? Self.poster : shifted }).isEmpty)
        XCTAssertTrue(SmartCleanAnalyzer.videoDuplicateClusters(items).isEmpty)
    }

    func testDifferentFramesStayApart() {
        let items = [
            Item(id: "a", duration: 10, hash: 0),
            Item(id: "b", duration: 10, hash: UInt64.max),
        ]
        XCTAssertTrue(SmartCleanAnalyzer.videoDuplicateClusters(items, pixels: Self.samePoster).isEmpty)
    }

    /// Ролики с чёрной обложкой одной длины — не дубли: хэш тёмного кадра случаен.
    func testFlatPosterFramesAreNotCompared() {
        let dark = [
            Item(id: "a", duration: 15, hash: 0b1010_1010, contrast: 2),
            Item(id: "b", duration: 15.5, hash: 0b1010_1010, contrast: 1),
        ]
        XCTAssertTrue(SmartCleanAnalyzer.videoDuplicateClusters(dark, pixels: Self.samePoster).isEmpty)
        let bright = [
            Item(id: "a", duration: 15, hash: 0b1010_1010, contrast: 40),
            Item(id: "b", duration: 15.5, hash: 0b1010_1010, contrast: 35),
            Item(id: "legacy", duration: 15.2, hash: 0b1010_1010),
        ]
        XCTAssertEqual(SmartCleanAnalyzer.videoDuplicateClusters(bright, pixels: Self.samePoster).map(Set.init), [["a", "b", "legacy"]])
    }

    func testHammingDistance() {
        XCTAssertEqual(ImageMetrics.hammingDistance(0, 0), 0)
        XCTAssertEqual(ImageMetrics.hammingDistance(0b1111, 0), 4)
    }
}
