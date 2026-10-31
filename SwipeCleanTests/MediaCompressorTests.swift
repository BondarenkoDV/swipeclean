import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SwipeClean

final class MediaCompressorTests: XCTestCase {
    /// Шумная картинка: такая плохо сжимается, как настоящее фото, а не как однотонная заливка.
    /// Квадраты по 7 пикселей не совпадают с блоками JPEG 8×8: при совпадении каждый блок однотонный,
    /// исходник сжимается почти даром, а уменьшенная копия получается больше него.
    private func makeJPEG(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        var generator = SystemRandomNumberGenerator()
        let image = renderer.image { context in
            for x in stride(from: 0, to: width, by: 7) {
                for y in stride(from: 0, to: height, by: 7) {
                    UIColor(
                        red: .random(in: 0...1, using: &generator),
                        green: .random(in: 0...1, using: &generator),
                        blue: .random(in: 0...1, using: &generator),
                        alpha: 1
                    ).setFill()
                    context.fill(CGRect(x: x, y: y, width: 7, height: 7))
                }
            }
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "test"],
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixelSize(_ data: Data) throws -> (width: Int, height: Int, orientation: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (
            properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
            properties[kCGImagePropertyOrientation] as? Int ?? 1
        )
    }

    func testEveryLevelMakesPhotoSmaller() throws {
        let original = try makeJPEG(width: 3000, height: 2000)
        var previous = original.count
        for level in CompressionLevel.allCases {
            let result = try XCTUnwrap(MediaCompressor.encodePhoto(original, level: level), "\(level)")
            XCTAssertLessThan(result.data.count, original.count, "\(level)")
            // Чем ниже уровень, тем меньше файл.
            XCTAssertLessThanOrEqual(result.data.count, previous, "\(level)")
            previous = result.data.count
        }
    }

    func testLowLevelLimitsLongSide() throws {
        let original = try makeJPEG(width: 4000, height: 3000)
        let result = try XCTUnwrap(MediaCompressor.encodePhoto(original, level: .low))
        let size = try pixelSize(result.data)
        XCTAssertEqual(max(size.width, size.height), 2400)
        XCTAssertEqual(min(size.width, size.height), 1800)
    }

    func testHighLevelKeepsResolution() throws {
        let original = try makeJPEG(width: 1600, height: 1200)
        let result = try XCTUnwrap(MediaCompressor.encodePhoto(original, level: .high))
        let size = try pixelSize(result.data)
        XCTAssertEqual(size.width, 1600)
        XCTAssertEqual(size.height, 1200)
    }

    /// Повёрнутое фото «запекается»: пиксели поворачиваются, а ориентация в метаданных становится обычной.
    func testRotationIsBakedIn() throws {
        let original = try makeJPEG(width: 1200, height: 800, orientation: 6)
        let result = try XCTUnwrap(MediaCompressor.encodePhoto(original, level: .medium))
        let size = try pixelSize(result.data)
        XCTAssertEqual(size.orientation, 1)
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 1200)
    }

    func testGarbageIsRejected() {
        XCTAssertNil(MediaCompressor.encodePhoto(Data("not an image".utf8), level: .medium))
    }
}
