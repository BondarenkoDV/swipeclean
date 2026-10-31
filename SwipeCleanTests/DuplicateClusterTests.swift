import XCTest
@testable import SwipeClean

final class DuplicateClusterTests: XCTestCase {
    private typealias Item = SmartCleanAnalyzer.PhotoItem

    /// Яркость 64×64 «фотографии» с плавным узором: у копий она совпадает.
    private static let picture: [UInt8] = (0..<(64 * 64)).map { index in
        let x = Double(index % 64), y = Double(index / 64)
        return UInt8(128 + 60 * sin(x / 5) * cos(y / 7) + 30 * sin((x + y) / 9))
    }

    /// Тот же кадр, но в одном месте другое «выражение лица»: блок 8×8 светлее на 70.
    private static let otherShot: [UInt8] = picture.enumerated().map { index, value in
        let x = index % 64, y = index / 64
        return (24..<32).contains(x) && (20..<28).contains(y) ? UInt8(min(255, Int(value) + 70)) : value
    }

    private func item(
        _ id: String,
        _ hash: UInt64,
        size: (Int, Int) = (4032, 3024),
        contrast: Double? = 40,
        pixels: [UInt8]? = DuplicateClusterTests.picture
    ) -> Item {
        var item = Item(id: id, hash: hash, width: size.0, height: size.1, contrast: contrast)
        item.pixels = pixels
        return item
    }

    func testNearlyEqualHashesAreGrouped() {
        let base: UInt64 = 0x1234_5678_9ABC_DEF0
        let items = [item("a", base), item("b", base ^ 0b101), item("c", ~base)]
        XCTAssertEqual(SmartCleanAnalyzer.duplicateClusters(items).map(Set.init), [["a", "b"]])
    }

    func testFlatFramesAreNotDuplicates() {
        let items = [item("sky1", 0xFFFF, contrast: 2), item("sky2", 0xFFFF, contrast: 3)]
        XCTAssertTrue(SmartCleanAnalyzer.duplicateClusters(items).isEmpty)
    }

    func testDifferentProportionsAreNotDuplicates() {
        let items = [item("a", 0xABCD_EF01), item("b", 0xABCD_EF01, size: (3024, 3024))]
        XCTAssertTrue(SmartCleanAnalyzer.duplicateClusters(items).isEmpty)
    }

    func testMissingContrastIsResolvedOnDemand() {
        let items = [item("a", 0xABCD_EF01, contrast: nil), item("b", 0xABCD_EF01, contrast: nil)]
        var asked: [String] = []
        let clusters = SmartCleanAnalyzer.duplicateClusters(items, contrast: { id in
            asked.append(id)
            return 50
        })
        XCTAssertEqual(clusters.map(Set.init), [["a", "b"]])
        XCTAssertEqual(Set(asked), ["a", "b"])
    }

    /// Соседний кадр серии с другим выражением лица — не дубль, даже если хэш и цвета совпали.
    func testNearlySameShotIsNotDuplicate() {
        let items = [item("a", 0xABCD_EF01), item("b", 0xABCD_EF01, pixels: Self.otherShot)]
        XCTAssertTrue(SmartCleanAnalyzer.duplicateClusters(items).isEmpty)
    }

    /// Без попиксельной копии (например, оригинал только в iCloud) пару не предлагаем.
    func testMissingPixelsAreNotDuplicates() {
        let items = [item("a", 0xABCD_EF01, pixels: nil), item("b", 0xABCD_EF01, pixels: nil)]
        XCTAssertTrue(SmartCleanAnalyzer.duplicateClusters(items).isEmpty)
        let resolved = SmartCleanAnalyzer.duplicateClusters(items, pixels: { _ in Self.picture })
        XCTAssertEqual(resolved.map(Set.init), [["a", "b"]])
    }

    /// Пересохранённая копия чуть темнее и с шумом сжатия — это всё ещё тот же кадр.
    func testResavedCopyIsDuplicate() {
        let resaved = Self.picture.enumerated().map { index, value in
            UInt8(max(0, Int(value) - 6 + (index % 3) - 1))
        }
        let items = [item("a", 0xABCD_EF01), item("b", 0xABCD_EF01 ^ 0b1, pixels: resaved)]
        XCTAssertEqual(SmartCleanAnalyzer.duplicateClusters(items).map(Set.init), [["a", "b"]])
    }

    func testGroupKeepsIdentityAfterPruning() {
        let group = AssetGroup(assets: [], bestID: "best", id: "group-1")
        XCTAssertEqual(group.id, "group-1")
    }

    func testSameLayoutInDifferentColorsIsNotDuplicate() {
        let blue = Array([[UInt8]](repeating: [40, 90, 220], count: 16).joined())
        let purple = Array([[UInt8]](repeating: [150, 60, 200], count: 16).joined())
        var a = item("blue", 0xABCD_EF01)
        a.colors = blue
        var b = item("purple", 0xABCD_EF01)
        b.colors = purple
        var c = item("blue-copy", 0xABCD_EF01)
        c.colors = blue.map { $0 &+ 3 }
        XCTAssertEqual(SmartCleanAnalyzer.duplicateClusters([a, b, c]).map(Set.init), [["blue", "blue-copy"]])
    }

    /// Скриншоты одного приложения различаются текстом, которого хэш не видит: им нужны точный хэш и те же цвета.
    func testScreenshotsNeedExactHashAndCloseColors() {
        var shot = item("shot", 0xABCD_EF01)
        shot.isScreenshot = true
        var nearShot = item("near-shot", 0xABCD_EF01 ^ 1)
        nearShot.isScreenshot = true
        XCTAssertTrue(SmartCleanAnalyzer.duplicateClusters([shot, nearShot]).isEmpty)

        var sameShot = item("same-shot", 0xABCD_EF01)
        sameShot.isScreenshot = true
        XCTAssertEqual(SmartCleanAnalyzer.duplicateClusters([shot, sameShot]).map(Set.init), [["shot", "same-shot"]])

        shot.colors = [UInt8](repeating: 100, count: 48)
        sameShot.colors = [UInt8](repeating: 108, count: 48)
        XCTAssertTrue(SmartCleanAnalyzer.duplicateClusters([shot, sameShot]).isEmpty)

        var photo = item("photo", 0xABCD_EF01)
        photo.colors = [UInt8](repeating: 100, count: 48)
        var nearPhoto = item("near-photo", 0xABCD_EF01 ^ 1)
        nearPhoto.colors = [UInt8](repeating: 108, count: 48)
        XCTAssertEqual(SmartCleanAnalyzer.duplicateClusters([photo, nearPhoto]).map(Set.init), [["photo", "near-photo"]])
    }

    func testMissingColorsAreResolvedOnDemand() {
        let items = [item("a", 0xABCD_EF01), item("b", 0xABCD_EF01)]
        let clusters = SmartCleanAnalyzer.duplicateClusters(items, colors: { id in
            [UInt8](repeating: id == "a" ? 30 : 200, count: 48)
        })
        XCTAssertTrue(clusters.isEmpty)
    }

    func testOnlyExactCopiesAreGrouped() {
        let colors = Array([[UInt8]](repeating: [80, 120, 160], count: 16).joined())
        var a = item("a", 0xABCD_EF01)
        a.colors = colors
        var b = item("b", 0xABCD_EF01)
        b.colors = colors
        var c = item("c", 0xABCD_EF01 ^ 0b1, pixels: Self.otherShot)
        c.colors = colors
        let clusters = SmartCleanAnalyzer.duplicateClusters([a, b, c])
        XCTAssertEqual(clusters.map(Set.init), [["a", "b"]])
    }
}
