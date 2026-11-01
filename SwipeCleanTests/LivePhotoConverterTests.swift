import Photos
import SwiftData
import XCTest
@testable import SwipeClean

@MainActor
final class LivePhotoConverterTests: XCTestCase {
    func testStillPrefersEditedVersion() {
        XCTAssertEqual(LivePhotoConverter.stillResourceType(among: [.photo, .pairedVideo]), .photo)
        XCTAssertEqual(
            LivePhotoConverter.stillResourceType(among: [.photo, .pairedVideo, .fullSizePhoto, .fullSizePairedVideo, .adjustmentData]),
            .fullSizePhoto
        )
        XCTAssertNil(LivePhotoConverter.stillResourceType(among: [.pairedVideo]))
    }

    func testFilenameKeepsOriginalBaseName() {
        XCTAssertEqual(LivePhotoConverter.filename(original: "IMG_0001.HEIC", chosen: "IMG_0001.HEIC"), "IMG_0001.HEIC")
        // Версия с правками называется FullSizeRender: имя берётся у исходника, расширение — у правки.
        XCTAssertEqual(LivePhotoConverter.filename(original: "IMG_0001.HEIC", chosen: "FullSizeRender.jpg"), "IMG_0001.jpg")
        XCTAssertEqual(LivePhotoConverter.filename(original: nil, chosen: "FullSizeRender.jpg"), "FullSizeRender.jpg")
        XCTAssertEqual(LivePhotoConverter.filename(original: "", chosen: "IMG_2.HEIC"), "IMG_2.HEIC")
        XCTAssertEqual(LivePhotoConverter.filename(original: "IMG_3.HEIC", chosen: "render"), "IMG_3.HEIC")
    }

    func testSavingsIsEverythingButTheStill() {
        XCTAssertEqual(LivePhotoConverter.savings(total: 5_000_000, still: 2_000_000), 3_000_000)
        // Размер из оценки бывает больше суммы ресурсов: отрицательной экономии не бывает.
        XCTAssertEqual(LivePhotoConverter.savings(total: 1_000, still: 2_000), 0)
    }

    func testRoomNeedsStillsPlusMargin() {
        let margin = LivePhotoConverter.spaceMargin
        XCTAssertTrue(LivePhotoConverter.hasRoom(forStills: 100, available: nil))
        XCTAssertTrue(LivePhotoConverter.hasRoom(forStills: 100, available: 100 + margin))
        XCTAssertFalse(LivePhotoConverter.hasRoom(forStills: 101, available: 100 + margin))
    }

    func testBatchesKeepOrderAndSize() {
        let items = Array(0..<450)
        let batches = LivePhotoConverter.batches(items, size: 200)
        XCTAssertEqual(batches.map(\.count), [200, 200, 50])
        XCTAssertEqual(batches.flatMap { $0 }, items)
        XCTAssertTrue(LivePhotoConverter.batches([Int](), size: 200).isEmpty)
        XCTAssertEqual(LivePhotoConverter.batches([1, 2], size: 0), [[1, 2]])
    }

    func testOutcomeCountsOnlyReplacedPhotos() {
        let url = URL(fileURLWithPath: "/tmp/x")
        let stills = [
            LivePhotoConverter.PreparedStill(originalID: "a", url: url, filename: "a", originalTotal: 5_000, size: 2_000),
            LivePhotoConverter.PreparedStill(originalID: "b", url: url, filename: "b", originalTotal: 9_000, size: 1_000),
            LivePhotoConverter.PreparedStill(originalID: "c", url: url, filename: "c", originalTotal: 4_000, size: 3_000),
        ]
        // «b» удалили снаружи, пока готовились снимки: его копии нет, и экономия по нему не считается.
        let outcome = LivePhotoConverter.outcome(replaced: ["a": "a2", "c": "c2"], stills: stills)
        XCTAssertEqual(outcome.replaced, ["a": "a2", "c": "c2"])
        XCTAssertEqual(outcome.saved, 3_000 + 1_000)
    }

    func testSystemCancelIsRecognized() {
        XCTAssertTrue(LivePhotoConverter.isUserCancel(PHPhotosError(.userCancelled)))
        XCTAssertTrue(LivePhotoConverter.isUserCancel(NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.userCancelled.rawValue)))
        XCTAssertFalse(LivePhotoConverter.isUserCancel(NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.accessUserDenied.rawValue)))
        XCTAssertFalse(LivePhotoConverter.isUserCancel(LivePhotoConverter.Failure.writeFailed))
    }

    func testFetchSelectsOnlyLivePhotos() throws {
        let predicate = try XCTUnwrap(LivePhotoConverter.fetchOptions().predicate)
        XCTAssertTrue(predicate.predicateFormat.contains("mediaSubtypes"), predicate.predicateFormat)
    }

    // MARK: - Решения переходят на новые фото

    /// Контейнер должен жить всё время теста: контекст не держит его сам.
    private var container: ModelContainer?

    func testDecisionsMoveToReplacementPhotos() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ReviewedAsset.self, DailyStat.self, PinnedAlbum.self, configurations: configuration)
        self.container = container
        let store = ReviewStore(context: container.mainContext)
        store.record([
            ReviewStore.Decision(localIdentifier: "a", decision: .keep, fileSize: { 5_000 }),
            ReviewStore.Decision(localIdentifier: "b", decision: .trash, fileSize: { 9_000 }),
            ReviewStore.Decision(localIdentifier: "c", decision: .later, fileSize: { 4_000 }),
        ])

        store.transfer(["a": "a2", "b": "b2", "missing": "m2"], sizes: ["b2": 1_000])

        // Оставленное не всплывёт в разборе заново, корзина считает размер нового фото, «Позже» не тронуто.
        XCTAssertEqual(store.reviewedIDs, ["a2", "b2"])
        XCTAssertEqual(store.trashItems().map(\.localIdentifier), ["b2"])
        XCTAssertEqual(store.trashItems().first?.fileSize, 1_000)
        XCTAssertEqual(store.item(for: "a2")?.fileSize, 5_000)
        XCTAssertEqual(store.laterIDs(), ["c"])
        XCTAssertNil(store.item(for: "a"))
        XCTAssertEqual(store.trashCount, 1)
    }
}
