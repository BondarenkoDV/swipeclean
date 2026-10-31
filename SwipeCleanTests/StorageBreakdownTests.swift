import Photos
import XCTest
@testable import SwipeClean

final class StorageBreakdownTests: XCTestCase {
    private func kind(_ type: PHAssetMediaType, _ subtypes: PHAssetMediaSubtype = [], burst: Bool = false, hidden: Bool = false) -> MediaKind {
        MediaKind.of(mediaType: type, subtypes: subtypes, isBurst: burst, isHidden: hidden)
    }

    func testPhotoKinds() {
        XCTAssertEqual(kind(.image), .photos)
        XCTAssertEqual(kind(.image, .photoLive), .livePhotos)
        XCTAssertEqual(kind(.image, .photoScreenshot), .screenshots)
        XCTAssertEqual(kind(.image, .photoDepthEffect), .portraits)
        XCTAssertEqual(kind(.image, .photoPanorama), .panoramas)
        XCTAssertEqual(kind(.image, burst: true), .bursts)
        XCTAssertEqual(kind(.image, .photoHDR), .photos)
    }

    func testVideoKinds() {
        XCTAssertEqual(kind(.video), .videos)
        XCTAssertEqual(kind(.video, .videoHighFrameRate), .slowMotion)
        XCTAssertEqual(kind(.video, .videoTimelapse), .timelapses)
        XCTAssertEqual(kind(.video, .videoStreamed), .videos)
    }

    /// Каждое фото попадает ровно в один раздел: важнее то, что пользователь узнает в первую очередь.
    func testKindPriority() {
        XCTAssertEqual(kind(.image, .photoLive, hidden: true), .hidden)
        XCTAssertEqual(kind(.video, .videoHighFrameRate, hidden: true), .hidden)
        XCTAssertEqual(kind(.image, [.photoScreenshot, .photoLive]), .screenshots)
        XCTAssertEqual(kind(.image, .photoLive, burst: true), .bursts)
        XCTAssertEqual(kind(.image, [.photoLive, .photoDepthEffect]), .livePhotos)
    }

    func testBreakdownSumsKinds() {
        var media = MediaBreakdown()
        media.add(.photos, bytes: 3_000_000)
        media.add(.photos, bytes: 2_000_000)
        media.add(.videos, bytes: 40_000_000)
        media.add(.screenshots, bytes: 500_000)
        XCTAssertEqual(media[.photos], MediaBreakdown.Usage(count: 2, bytes: 5_000_000))
        XCTAssertEqual(media[.bursts], MediaBreakdown.Usage())
        XCTAssertEqual(media.totalBytes, 45_500_000)
        XCTAssertEqual(media.totalCount, 4)
        XCTAssertEqual(media.kinds, [.videos, .photos, .screenshots], "Пустые разделы скрыты, тяжёлые первыми")
    }

    func testRemainderIsAppsAndSystem() {
        let device = DeviceStorage(total: 128_000, available: 28_000)
        let breakdown = StorageBreakdown(device: device, media: 40_000, app: 1_000)
        XCTAssertEqual(device.used, 100_000)
        XCTAssertEqual(breakdown.mediaOnDevice, 40_000)
        XCTAssertEqual(breakdown.other, 59_000)
        XCTAssertFalse(breakdown.isMediaPartlyInCloud)
        XCTAssertEqual(breakdown.fraction(breakdown.mediaOnDevice) + breakdown.fraction(breakdown.app)
            + breakdown.fraction(breakdown.other) + breakdown.fraction(device.available), 1, accuracy: 1e-9)
    }

    /// С «Оптимизацией хранилища» оригиналы больше занятого места: полоса не должна вылезать за край.
    func testMediaLargerThanUsedSpace() {
        let device = DeviceStorage(total: 128_000, available: 78_000)
        let breakdown = StorageBreakdown(device: device, media: 90_000, app: 2_000)
        XCTAssertTrue(breakdown.isMediaPartlyInCloud)
        XCTAssertEqual(breakdown.mediaOnDevice, 48_000)
        XCTAssertEqual(breakdown.other, 0)
        XCTAssertEqual(breakdown.onDevice(45_000), 24_000, "Раздел уменьшается в той же пропорции, что и вся медиатека")
        XCTAssertLessThanOrEqual(breakdown.fraction(breakdown.mediaOnDevice + breakdown.app + breakdown.other), breakdown.fraction(device.used) + 1e-9)
    }

    func testAllocatedSizeCountsFilesInSubfolders() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(count: 100_000).write(to: directory.appendingPathComponent("a.bin"))
        try Data(count: 50_000).write(to: nested.appendingPathComponent("b.bin"))
        let size = AppFootprint.allocatedSize(of: directory)
        // Место на диске выделяется блоками, поэтому чуть больше суммы размеров файлов.
        XCTAssertGreaterThanOrEqual(size, 150_000)
        XCTAssertLessThan(size, 200_000)
        XCTAssertEqual(AppFootprint.allocatedSize(of: directory.appendingPathComponent("missing")), 0)
    }
}
