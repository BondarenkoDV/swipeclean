import CoreGraphics
import Vision

/// Выбор лучшего кадра в «Похожих» и «Сериях» по лицам: открыты ли глаза и насколько хорошо снято лицо.
/// Качество лица даёт Vision (`VNDetectFaceCaptureQualityRequest`): Apple обучала его ранжировать снимки
/// одного человека с учётом света, смаза, фокуса, поворота головы и выражения лица. Открытые глаза
/// проверяются отдельно по точкам век (`VNDetectFaceLandmarksRequest`): моргнувший человек портит кадр
/// сильнее, чем это видно по общему качеству. Если лиц нет, лучший кадр выбирается как раньше, по резкости.
/// Все функции синхронные и вызываются вне главного потока.
enum FaceQuality {
    /// Лицо на кадре.
    struct Face: Equatable, Sendable {
        /// Качество лица по Vision, 0…1: ближе к 1 — лучше свет, резче, лицо смотрит в камеру.
        var quality: Float
        /// Открыты ли глаза; `nil`, если Vision не нашёл точек глаз (тогда кадр за них не штрафуется).
        var eyesOpen: Bool?
    }

    /// Что известно о кадре группы, чтобы выбрать лучший.
    struct Shot: Sendable {
        let id: String
        var isFavorite = false
        /// Кадр, который камера сама выбрала обложкой серии.
        var isCameraPick = false
        /// Резкость всего кадра (дисперсия лапласиана, см. `ImageMetrics.sharpness`).
        var sharpness = 0.0
        /// Лица на кадре; `nil`, если кадр проверить не удалось (нет превью без сети).
        var faces: [Face]? = nil
    }

    /// Резкость и лица одного кадра — результат проверки.
    struct Analysis: Sendable {
        var sharpness: Double
        var faces: [Face]?
    }

    /// Глаз считается закрытым, если высота разреза меньше этой доли его ширины.
    /// У открытого глаза отношение около 0,25–0,4, у закрытого — около 0,05; в работе Soukupová и Čech (2016)
    /// порог моргания 0,2. Берём чуть ниже, чтобы прищур при улыбке не считался закрытыми глазами.
    static let closedEyeRatio = 0.18
    /// Во сколько раз обесценивается лицо с закрытыми глазами: такой кадр почти никогда не лучший.
    static let closedEyesPenalty = 0.3
    /// Лица меньше этой доли площади самого крупного лица на кадре — прохожие на фоне, их не учитываем.
    static let minRelativeFaceArea = 0.25
    /// Лица уже этой доли ширины кадра слишком мелкие, чтобы судить о глазах и чёткости.
    static let minFaceWidth = 0.04
    /// Доля лиц в оценке кадра; остальное — резкость всего кадра относительно самого резкого в группе.
    static let faceWeight = 0.8
    /// Кадры, чьи оценки отличаются меньше чем на столько, считаются равными: тогда решает выбор камеры.
    static let tieTolerance = 0.02

    // MARK: - Выбор лучшего

    /// Почему кадр назван лучшим: подпись под группой.
    enum Reason: Sendable, Equatable {
        /// Кадр в избранном.
        case favorite
        /// Пользователь сам отметил кадр в серии.
        case chosen
        /// Лучший по лицам: открытые глаза и качество лиц.
        case faces
        /// Лиц нет, выбран кадр, который камера сделала обложкой серии.
        case camera
        /// Лиц нет, выбран самый резкий кадр.
        case sharpness
    }

    /// Лучший кадр группы: избранное, затем лучший по лицам, затем выбор камеры для серии, затем самый резкий.
    static func best(among shots: [Shot]) -> (id: String, reason: Reason)? {
        guard !shots.isEmpty else { return nil }
        if let favorite = shots.first(where: \.isFavorite) { return (favorite.id, .favorite) }
        if let byFaces = bestByFaces(shots) { return (byFaces, .faces) }
        if let camera = shots.first(where: \.isCameraPick) { return (camera.id, .camera) }
        let sharpest = shots.max { $0.sharpness < $1.sharpness } ?? shots[0]
        return (sharpest.id, .sharpness)
    }

    /// Лучший кадр по лицам или `nil`, если лиц нет ни на одном кадре.
    /// Оценка кадра — среднее качество лиц, где лицо с закрытыми глазами обесценено, плюс немного резкости.
    /// Среднее берётся по наибольшему числу лиц в группе: если кто-то отвернулся и его лицо не нашлось,
    /// это лицо считается нулём, и кадр, где видны все, выигрывает.
    static func bestByFaces(_ shots: [Shot]) -> String? {
        let expected = shots.compactMap { $0.faces?.count }.max() ?? 0
        guard expected > 0 else { return nil }
        let sharpest = shots.map(\.sharpness).max() ?? 0
        let scored = shots.map { shot -> (shot: Shot, score: Double) in
            (shot, score(shot, expectedFaces: expected, sharpest: sharpest))
        }
        guard let top = scored.map({ $0.score }).max() else { return nil }
        // Почти равные кадры: лучше тот, что выбрала камера, иначе — с наибольшей оценкой, при равенстве более ранний.
        let leaders = scored.filter { top - $0.score <= tieTolerance }
        let pick = leaders.first { $0.shot.isCameraPick } ?? leaders.max { $0.score < $1.score }
        return pick?.shot.id
    }

    /// Оценка кадра 0…1; кадр, который не удалось проверить, ниже любого проверенного.
    static func score(_ shot: Shot, expectedFaces: Int, sharpest: Double) -> Double {
        guard let faces = shot.faces, expectedFaces > 0 else { return -1 }
        let facesTotal = faces
            .sorted { $0.quality > $1.quality }
            .prefix(expectedFaces)
            .reduce(0.0) { $0 + Double($1.quality) * ($1.eyesOpen == false ? closedEyesPenalty : 1) }
        let sharpness = sharpest > 0 ? shot.sharpness / sharpest : 0
        return faceWeight * facesTotal / Double(expectedFaces) + (1 - faceWeight) * sharpness
    }

    // MARK: - Лица на кадре

    /// Лица на кадре: пустой массив, если лиц нет, и `nil`, если Vision не смог обработать кадр.
    static func faces(in image: CGImage) -> [Face]? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let rectangles = VNDetectFaceRectanglesRequest()
        ImageMetrics.preferCPUOnSimulator(rectangles)
        do {
            try handler.perform([rectangles])
        } catch {
            return nil
        }
        let main = mainFaces(rectangles.results ?? [])
        guard !main.isEmpty else { return [] }

        // Точки глаз и качество считаются по уже найденным лицам, второй раз их не ищем.
        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.inputFaceObservations = main
        ImageMetrics.preferCPUOnSimulator(landmarks)
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = main
        ImageMetrics.preferCPUOnSimulator(quality)
        // Если одна из проверок не удалась, лицо всё равно учитывается: без качества оно получает середину шкалы.
        try? handler.perform([landmarks, quality])
        let withLandmarks = landmarks.results ?? []
        let withQuality = quality.results ?? []
        let size = CGSize(width: image.width, height: image.height)

        return main.map { face in
            let score = nearest(to: face, in: withQuality)?.faceCaptureQuality ?? 0.5
            var eyesOpen: Bool?
            if let points = nearest(to: face, in: withLandmarks)?.landmarks {
                let ratios = [points.leftEye, points.rightEye].compactMap { region in
                    region.flatMap { eyeOpenness($0.pointsInImage(imageSize: size)) }
                }
                // Среднее двух глаз: моргание закрывает оба, а неточность одной точки не решает.
                if !ratios.isEmpty {
                    eyesOpen = ratios.reduce(0, +) / Double(ratios.count) >= closedEyeRatio
                }
            }
            return Face(quality: score, eyesOpen: eyesOpen)
        }
    }

    /// Лица, которые стоит учитывать: не мельче `minFaceWidth` и не меньше четверти самого крупного лица.
    static func mainFaces(_ faces: [VNFaceObservation]) -> [VNFaceObservation] {
        let areas = faces.map { Double($0.boundingBox.width * $0.boundingBox.height) }
        let largest = areas.max() ?? 0
        return zip(faces, areas).compactMap { face, area in
            guard Double(face.boundingBox.width) >= minFaceWidth, area >= minRelativeFaceArea * largest else { return nil }
            return face
        }
    }

    /// Насколько открыт глаз: высота контура века, делённая на расстояние между уголками глаза.
    /// Уголки — самая дальняя пара точек контура, высота считается поперёк линии уголков,
    /// поэтому наклон головы на результат не влияет. `nil`, если точек слишком мало.
    static func eyeOpenness(_ points: [CGPoint]) -> Double? {
        guard points.count >= 4 else { return nil }
        var corners = (points[0], points[0])
        var width = 0.0
        for i in points.indices {
            for j in points.indices where j > i {
                let distance = hypot(Double(points[j].x - points[i].x), Double(points[j].y - points[i].y))
                if distance > width {
                    width = distance
                    corners = (points[i], points[j])
                }
            }
        }
        guard width > 0 else { return nil }
        let axisX = Double(corners.1.x - corners.0.x) / width
        let axisY = Double(corners.1.y - corners.0.y) / width
        let offsets = points.map { point in
            Double(point.x - corners.0.x) * -axisY + Double(point.y - corners.0.y) * axisX
        }
        guard let top = offsets.max(), let bottom = offsets.min() else { return nil }
        return (top - bottom) / width
    }

    /// Результат другой проверки для того же лица: ближайший по центру рамки.
    private static func nearest(to face: VNFaceObservation, in candidates: [VNFaceObservation]) -> VNFaceObservation? {
        if let same = candidates.first(where: { $0.uuid == face.uuid }) { return same }
        let center = CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY)
        func distance(_ other: VNFaceObservation) -> CGFloat {
            hypot(other.boundingBox.midX - center.x, other.boundingBox.midY - center.y)
        }
        // Чужое лицо дальше половины ширины рамки: у этого лица результата нет.
        guard let closest = candidates.min(by: { distance($0) < distance($1) }),
              distance(closest) <= face.boundingBox.width / 2
        else { return nil }
        return closest
    }
}
