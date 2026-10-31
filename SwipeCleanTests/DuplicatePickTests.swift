import XCTest
@testable import SwipeClean

final class DuplicatePickTests: XCTestCase {
    private typealias Candidate = SmartCleanAnalyzer.DuplicateCandidate

    private let older = Date(timeIntervalSince1970: 1_700_000_000)
    private let newer = Date(timeIntervalSince1970: 1_700_100_000)

    func testFavoriteWinsOverResolution() {
        let candidates = [
            Candidate(id: "big", pixels: 12_000_000),
            Candidate(id: "favorite", isFavorite: true, pixels: 2_000_000),
        ]
        XCTAssertEqual(SmartCleanAnalyzer.bestDuplicate(among: candidates), "favorite")
    }

    /// Копия из мессенджера пережата и меньше оригинала.
    func testHigherResolutionWinsOverLivePhoto() {
        let candidates = [
            Candidate(id: "live-small", pixels: 2_000_000, isLivePhoto: true),
            Candidate(id: "original", pixels: 12_000_000),
        ]
        XCTAssertEqual(SmartCleanAnalyzer.bestDuplicate(among: candidates), "original")
    }

    func testLivePhotoWinsAtSameResolution() {
        let candidates = [
            Candidate(id: "still", pixels: 12_000_000, sharpness: 100),
            Candidate(id: "live", pixels: 12_000_000, isLivePhoto: true, sharpness: 100),
        ]
        XCTAssertEqual(SmartCleanAnalyzer.bestDuplicate(among: candidates), "live")
    }

    func testClearlySharperWinsButSmallDifferenceFallsBackToAge() {
        let sharper = [
            Candidate(id: "soft", pixels: 1, sharpness: 80, creationDate: older),
            Candidate(id: "sharp", pixels: 1, sharpness: 100, creationDate: newer),
        ]
        XCTAssertEqual(SmartCleanAnalyzer.bestDuplicate(among: sharper), "sharp")

        let almostEqual = [
            Candidate(id: "copy", pixels: 1, sharpness: 101, creationDate: newer),
            Candidate(id: "original", pixels: 1, sharpness: 100, creationDate: older),
        ]
        XCTAssertEqual(SmartCleanAnalyzer.bestDuplicate(among: almostEqual), "original")
    }

    func testLargerFileBreaksRemainingTies() {
        let candidates = [
            Candidate(id: "small", pixels: 1, creationDate: older, fileSize: 1_000),
            Candidate(id: "large", pixels: 1, creationDate: older, fileSize: 2_000),
        ]
        XCTAssertEqual(SmartCleanAnalyzer.bestDuplicate(among: candidates), "large")
        XCTAssertNil(SmartCleanAnalyzer.bestDuplicate(among: []))
    }
}
