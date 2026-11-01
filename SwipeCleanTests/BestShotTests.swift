import CoreGraphics
import XCTest
@testable import SwipeClean

/// Выбор лучшего кадра в «Похожих» и «Сериях»: лица, открытые глаза, резкость, избранное и выбор камеры.
final class BestShotTests: XCTestCase {
    private typealias Shot = FaceQuality.Shot
    private typealias Face = FaceQuality.Face

    func testFavoriteWinsOverBetterFaces() {
        let shots = [
            Shot(id: "faces", sharpness: 200, faces: [Face(quality: 0.9, eyesOpen: true)]),
            Shot(id: "favorite", isFavorite: true, sharpness: 50, faces: [Face(quality: 0.2, eyesOpen: false)]),
        ]
        XCTAssertEqual(FaceQuality.best(among: shots)?.id, "favorite")
        XCTAssertEqual(FaceQuality.best(among: shots)?.reason, .favorite)
    }

    /// Моргнувший человек проигрывает, даже если кадр резче, а качество лица почти то же.
    func testOpenEyesBeatSharperBlink() {
        let shots = [
            Shot(id: "blink", sharpness: 300, faces: [Face(quality: 0.62, eyesOpen: false)]),
            Shot(id: "open", sharpness: 200, faces: [Face(quality: 0.58, eyesOpen: true)]),
        ]
        XCTAssertEqual(FaceQuality.best(among: shots)?.id, "open")
        XCTAssertEqual(FaceQuality.best(among: shots)?.reason, .faces)
    }

    /// На групповом фото выигрывает кадр, где глаза открыты у всех.
    func testGroupPhotoPrefersEveryoneWithOpenEyes() {
        let shots = [
            Shot(id: "one-blinked", sharpness: 100, faces: [
                Face(quality: 0.7, eyesOpen: true), Face(quality: 0.7, eyesOpen: false), Face(quality: 0.7, eyesOpen: true),
            ]),
            Shot(id: "all-open", sharpness: 100, faces: [
                Face(quality: 0.6, eyesOpen: true), Face(quality: 0.6, eyesOpen: true), Face(quality: 0.6, eyesOpen: true),
            ]),
        ]
        XCTAssertEqual(FaceQuality.best(among: shots)?.id, "all-open")
    }

    /// Если кто-то отвернулся и его лицо не нашлось, кадр, где видны все, лучше.
    func testMissingFaceCountsAgainstShot() {
        let shots = [
            Shot(id: "turned-away", sharpness: 100, faces: [Face(quality: 0.8, eyesOpen: true)]),
            Shot(id: "both", sharpness: 100, faces: [Face(quality: 0.6, eyesOpen: true), Face(quality: 0.6, eyesOpen: true)]),
        ]
        XCTAssertEqual(FaceQuality.best(among: shots)?.id, "both")
    }

    /// Сильно смазанное лицо с открытыми глазами хуже чёткого, где один из пяти чуть прикрыл глаза.
    func testBlurredFacesLoseToSharpOnesWithOneBlink() {
        let blurred = Array(repeating: Face(quality: 0.15, eyesOpen: true), count: 5)
        let sharp = Array(repeating: Face(quality: 0.7, eyesOpen: true), count: 4) + [Face(quality: 0.7, eyesOpen: false)]
        let shots = [
            Shot(id: "blurred", sharpness: 40, faces: blurred),
            Shot(id: "sharp", sharpness: 120, faces: sharp),
        ]
        XCTAssertEqual(FaceQuality.best(among: shots)?.id, "sharp")
    }

    func testBetterFaceQualityWins() {
        let shots = [
            Shot(id: "dim", sharpness: 100, faces: [Face(quality: 0.3, eyesOpen: true)]),
            Shot(id: "lit", sharpness: 100, faces: [Face(quality: 0.7, eyesOpen: true)]),
            Shot(id: "unknown-eyes", sharpness: 100, faces: [Face(quality: 0.5, eyesOpen: nil)]),
        ]
        XCTAssertEqual(FaceQuality.best(among: shots)?.id, "lit")
    }

    /// Почти равные кадры серии: решает выбор камеры.
    func testCameraPickBreaksNearTie() {
        let shots = [
            Shot(id: "first", sharpness: 100, faces: [Face(quality: 0.71, eyesOpen: true)]),
            Shot(id: "camera", isCameraPick: true, sharpness: 100, faces: [Face(quality: 0.70, eyesOpen: true)]),
        ]
        XCTAssertEqual(FaceQuality.best(among: shots)?.id, "camera")
    }

    /// Кадр, который не удалось проверить, не становится лучшим, если остальные проверены.
    func testUncheckedShotLoses() {
        let shots = [
            Shot(id: "unchecked", sharpness: 500, faces: nil),
            Shot(id: "checked", sharpness: 50, faces: [Face(quality: 0.2, eyesOpen: false)]),
        ]
        XCTAssertEqual(FaceQuality.best(among: shots)?.id, "checked")
    }

    /// Без лиц всё как раньше: в серии — выбор камеры, в похожих — самый резкий кадр.
    func testWithoutFacesFallsBackToCameraThenSharpness() {
        let burst = [
            Shot(id: "sharp", sharpness: 300, faces: []),
            Shot(id: "camera", isCameraPick: true, sharpness: 100, faces: []),
        ]
        XCTAssertEqual(FaceQuality.best(among: burst)?.id, "camera")
        XCTAssertEqual(FaceQuality.best(among: burst)?.reason, .camera)

        let similar = [
            Shot(id: "soft", sharpness: 80, faces: []),
            Shot(id: "sharp", sharpness: 300, faces: nil),
        ]
        XCTAssertEqual(FaceQuality.best(among: similar)?.id, "sharp")
        XCTAssertEqual(FaceQuality.best(among: similar)?.reason, .sharpness)
        XCTAssertNil(FaceQuality.best(among: []))
    }

    // MARK: - Открытые глаза по точкам века

    /// Контур глаза из 8 точек: уголки и по три точки на верхнем и нижнем веке.
    private func eye(width: Double, height: Double, angle: Double = 0) -> [CGPoint] {
        let raw: [(Double, Double)] = [
            (0, 0), (0.25, height / 2), (0.5, height / 2), (0.75, height / 2),
            (1, 0), (0.75, -height / 2), (0.5, -height / 2), (0.25, -height / 2),
        ]
        return raw.map { x, y in
            let px = x * width, py = y * width
            return CGPoint(x: 100 + px * cos(angle) - py * sin(angle), y: 50 + px * sin(angle) + py * cos(angle))
        }
    }

    func testEyeOpennessSeparatesOpenAndClosedEyes() throws {
        let open = try XCTUnwrap(FaceQuality.eyeOpenness(eye(width: 40, height: 0.35)))
        let closed = try XCTUnwrap(FaceQuality.eyeOpenness(eye(width: 40, height: 0.05)))
        XCTAssertEqual(open, 0.35, accuracy: 0.01)
        XCTAssertEqual(closed, 0.05, accuracy: 0.01)
        XCTAssertGreaterThan(open, FaceQuality.closedEyeRatio)
        XCTAssertLessThan(closed, FaceQuality.closedEyeRatio)
    }

    /// Наклон головы не меняет оценку: высота меряется поперёк линии уголков глаза.
    func testEyeOpennessIgnoresHeadTilt() throws {
        let tilted = try XCTUnwrap(FaceQuality.eyeOpenness(eye(width: 40, height: 0.35, angle: .pi / 6)))
        XCTAssertEqual(tilted, 0.35, accuracy: 0.01)
        XCTAssertNil(FaceQuality.eyeOpenness([CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)]))
        XCTAssertNil(FaceQuality.eyeOpenness(Array(repeating: CGPoint(x: 3, y: 3), count: 6)))
    }

    // MARK: - Vision

    /// Картинка без лиц: Vision отрабатывает (в том числе в симуляторе на процессоре) и лиц не находит.
    func testFacesOnPlainImageAreEmpty() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(FaceQuality.faces(in: image), [])
    }
}
