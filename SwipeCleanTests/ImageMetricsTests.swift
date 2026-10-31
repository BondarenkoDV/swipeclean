import CoreGraphics
import UIKit
import XCTest
@testable import SwipeClean

final class ImageMetricsTests: XCTestCase {
    /// Шахматная доска даёт резкие края, однотонная картинка — нулевой лапласиан.
    private func image(size: Int = 128, pattern: (Int, Int) -> UInt8) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                pixels[y * size + x] = pattern(x, y)
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: size, height: size,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    func testFlatImageHasZeroSharpness() {
        let flat = image { _, _ in 128 }
        XCTAssertEqual(ImageMetrics.sharpness(flat), 0, accuracy: 0.001)
    }

    func testCheckerboardIsSharperThanGradient() {
        let checker = image { x, y in ((x / 4 + y / 4) % 2 == 0) ? 0 : 255 }
        let gradient = image { x, _ in UInt8(x * 2) }
        XCTAssertGreaterThan(ImageMetrics.sharpness(checker), ImageMetrics.sharpness(gradient))
        XCTAssertGreaterThan(ImageMetrics.sharpness(checker), SmartCleanAnalyzer.blurThreshold)
    }

    /// Повёрнутый кадр хэшируется так, как он показывается, а не как лежит в файле.
    func testUprightImageFollowsOrientation() {
        let falling = image(size: 128) { x, _ in UInt8(255 - x * 2) }
        // Горизонтальный градиент: почти все соседи по горизонтали различаются, хэш далёк от нуля.
        let fallingHash = ImageMetrics.differenceHash(falling)
        XCTAssertGreaterThan(fallingHash.nonzeroBitCount, 48)

        let rotated = UIImage(cgImage: falling, scale: 1, orientation: .right)
        let upright = ImageMetrics.uprightCGImage(rotated)
        XCTAssertEqual(upright?.width, 128)
        XCTAssertEqual(upright?.height, 128)
        // После поворота градиент вертикальный: соседи по горизонтали равны, хэш нулевой.
        XCTAssertEqual(upright.map(ImageMetrics.differenceHash), 0)

        let plain = UIImage(cgImage: falling, scale: 1, orientation: .up)
        XCTAssertEqual(ImageMetrics.uprightCGImage(plain).map(ImageMetrics.differenceHash), fallingHash)
    }

    func testContrastAndColorSignature() {
        let flat = image { _, _ in 128 }
        let checker = image { x, y in ((x / 4 + y / 4) % 2 == 0) ? 0 : 255 }
        XCTAssertEqual(ImageMetrics.contrast(flat), 0, accuracy: 0.001)
        XCTAssertGreaterThan(ImageMetrics.contrast(checker), SmartCleanAnalyzer.duplicateMinContrast)

        let signature = ImageMetrics.colorSignature(flat)
        XCTAssertEqual(signature?.count, 48)
        XCTAssertTrue(signature?.allSatisfy { abs(Int($0) - 128) <= 3 } ?? false)
        XCTAssertEqual(ImageMetrics.colorDifference(signature ?? [], signature ?? []), 0)
        XCTAssertEqual(ImageMetrics.colorDifference([0, 0, 0], [10, 20, 30]), 20)
    }

    func testDifferenceHashIsStableAndDistinguishes() {
        let gradient = image { x, _ in UInt8(x * 2) }
        let reversed = image { x, _ in UInt8(255 - x * 2) }
        XCTAssertEqual(ImageMetrics.differenceHash(gradient), ImageMetrics.differenceHash(gradient))
        XCTAssertNotEqual(ImageMetrics.differenceHash(gradient), ImageMetrics.differenceHash(reversed))
    }

    /// Плавный узор вроде фотографии: однотонные области и края без мелкого муара.
    private func photo(width: Int, height: Int, change: CGRect? = nil) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width) * 64, v = Double(y) / Double(height) * 64
                var value = 128 + 60 * sin(u / 5) * cos(v / 7) + 30 * sin((u + v) / 9)
                if let change, change.contains(CGPoint(x: Double(x) / Double(width), y: Double(y) / Double(height))) {
                    value += 70
                }
                pixels[y * width + x] = UInt8(max(0, min(255, value)))
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }

    /// Уменьшенная копия того же кадра — дубль, а кадр с изменённым местом (другое выражение лица) — нет.
    func testFineSignatureMatchesResizedCopyOnly() throws {
        let original = try XCTUnwrap(ImageMetrics.fineSignature(photo(width: 400, height: 300)))
        let smaller = try XCTUnwrap(ImageMetrics.fineSignature(photo(width: 320, height: 240)))
        let changed = try XCTUnwrap(ImageMetrics.fineSignature(
            photo(width: 400, height: 300, change: CGRect(x: 0.4, y: 0.3, width: 0.12, height: 0.12))
        ))
        XCTAssertEqual(original.count, ImageMetrics.fineSide * ImageMetrics.fineSide)
        XCTAssertTrue(SmartCleanAnalyzer.isSamePicture(original, smaller))
        XCTAssertFalse(SmartCleanAnalyzer.isSamePicture(original, changed))
    }

    func testFineDifferenceIgnoresGlobalBrightnessShift() {
        let base = (0..<(64 * 64)).map { UInt8(($0 % 64) * 2 + 40) }
        let darker = base.map { $0 - 10 }
        let difference = ImageMetrics.fineDifference(base, darker)
        XCTAssertEqual(difference.mean, 0, accuracy: 0.001)
        XCTAssertEqual(difference.worstBlock, 0, accuracy: 0.001)
        XCTAssertEqual(ImageMetrics.fineDifference(base, [1, 2, 3]).mean, .infinity)
    }
}
