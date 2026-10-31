import SwiftData
import XCTest
@testable import SwipeClean

@MainActor
final class ReviewStoreTests: XCTestCase {
    /// Контейнер должен жить всё время теста: контекст не держит его сам.
    private var container: ModelContainer?

    private func makeStore() throws -> ReviewStore {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ReviewedAsset.self, DailyStat.self, PinnedAlbum.self, configurations: configuration)
        self.container = container
        return ReviewStore(context: container.mainContext)
    }

    private func decision(_ id: String, _ decision: SwipeDecision, size: Int64 = 10) -> ReviewStore.Decision {
        ReviewStore.Decision(localIdentifier: id, decision: decision, fileSize: { size })
    }

    func testBatchRecordCountsTrashAndReviewed() throws {
        let store = try makeStore()
        store.record([decision("a", .trash), decision("b", .keep), decision("c", .later)])
        XCTAssertEqual(store.trashCount, 1)
        XCTAssertEqual(store.reviewedIDs, ["a", "b"])
        XCTAssertEqual(store.today().reviewed, 3)
        XCTAssertEqual(store.trashItems().map(\.localIdentifier), ["a"])
        XCTAssertEqual(store.laterIDs(), ["c"])
    }

    func testRepeatedDecisionDoesNotInflateStats() throws {
        let store = try makeStore()
        store.record([decision("a", .keep)])
        store.record([decision("a", .trash)])
        XCTAssertEqual(store.today().reviewed, 1)
        XCTAssertEqual(store.trashCount, 1)
        XCTAssertEqual(store.count(of: .trash), 1)
        XCTAssertEqual(store.count(of: .keep), 0)
    }

    func testLaterCountsAsReviewedOnceDecided() throws {
        let store = try makeStore()
        store.record([decision("a", .later)])
        XCTAssertFalse(store.reviewedIDs.contains("a"))
        store.record([decision("a", .keep)])
        XCTAssertTrue(store.reviewedIDs.contains("a"))
        XCTAssertEqual(store.today().reviewed, 2)
        XCTAssertTrue(store.laterIDs().isEmpty)
    }

    func testUndoRemovesRecordAndStat() throws {
        let store = try makeStore()
        store.record([decision("a", .trash)])
        store.undo(id: "a")
        XCTAssertEqual(store.trashCount, 0)
        XCTAssertTrue(store.reviewedIDs.isEmpty)
        XCTAssertEqual(store.today().reviewed, 0)
        XCTAssertNil(store.item(for: "a"))
    }

    func testUndoRestoresPreviousDecision() throws {
        let store = try makeStore()
        store.record([decision("a", .later)])
        store.record([decision("a", .trash)])
        store.undo(id: "a", restoring: .later)
        XCTAssertEqual(store.laterIDs(), ["a"])
        XCTAssertEqual(store.trashCount, 0)
        XCTAssertFalse(store.reviewedIDs.contains("a"))
        XCTAssertEqual(store.today().reviewed, 1)

        store.record([decision("b", .keep)])
        store.record([decision("b", .trash)])
        store.undo(id: "b", restoring: .keep)
        XCTAssertEqual(store.item(for: "b")?.decision, .keep)
        XCTAssertTrue(store.reviewedIDs.contains("b"))
        XCTAssertEqual(store.today().reviewed, 2)
    }

    func testRestoreAndForgetMissing() throws {
        let store = try makeStore()
        store.record([decision("a", .trash), decision("b", .trash)])
        store.restore(["a"])
        XCTAssertEqual(store.trashCount, 1)
        XCTAssertEqual(store.count(of: .keep, excludingDeleted: true), 1)
        store.forgetMissing(["b"])
        XCTAssertEqual(store.trashCount, 0)
        XCTAssertEqual(store.count(of: .keep, excludingDeleted: true), 1)
        XCTAssertEqual(store.count(of: .keep), 2)
    }

    /// Повторное «позже» в подборке «Решу позже» не считается новым разбором.
    func testLaterAgainDoesNotCountAsReviewed() throws {
        let store = try makeStore()
        store.record([decision("a", .later)])
        store.record([decision("a", .later)])
        XCTAssertEqual(store.today().reviewed, 1)
        XCTAssertEqual(store.laterIDs(), ["a"])
        store.record([decision("a", .keep)])
        XCTAssertEqual(store.today().reviewed, 2)
    }

    /// После сброса хранилище пустое, а новая запись за сегодня создаётся без конфликта с удалённой.
    func testResetClearsDecisionsAndStats() throws {
        let store = try makeStore()
        store.record([decision("a", .trash), decision("b", .keep)])
        store.resetProgress()
        XCTAssertTrue(store.reviewedIDs.isEmpty)
        XCTAssertEqual(store.trashCount, 0)
        XCTAssertNil(store.item(for: "a"))
        XCTAssertEqual(store.today().reviewed, 0)
        store.record([decision("a", .keep)])
        XCTAssertEqual(store.today().reviewed, 1)
        XCTAssertEqual(store.count(of: .keep), 1)
    }
}
