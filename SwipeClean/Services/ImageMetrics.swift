import CoreGraphics
import UIKit
import Vision
#if targetEnvironment(simulator)
import CoreML
#endif

/// Метрики изображения для умной чистки. Все функции синхронные и вызываются вне главного потока.
enum ImageMetrics {
    /// Ревизия отпечатков Vision. Она задаётся явно: по умолчанию Vision берёт последнюю ревизию SDK,
    /// а у разных ревизий разная длина вектора и шкала расстояний (ревизия 1 — 2048 чисел и расстояния до ~40,
    /// ревизия 2 — 768 чисел и расстояния до 2). Без фиксации пороги и кэш ломались бы после обновления Xcode.
    static let featurePrintRevision = VNGenerateImageFeaturePrintRequestRevision2

    /// Отпечаток Vision для поиска похожих кадров.
    static func featurePrint(_ image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = featurePrintRevision
        preferCPUOnSimulator(request)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return request.results?.first
    }

    /// В симуляторе Vision по умолчанию не создаёт контекст нейросети («Failed to create espresso context»):
    /// отпечатков и оценок лиц нет, и «Похожие» всегда пустые. На процессоре всё считается. На устройстве путь прежний.
    static func preferCPUOnSimulator(_ request: VNRequest) {
        #if targetEnvironment(simulator)
        let devices = (try? request.supportedComputeStageDevices[.main]) ?? []
        if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
            request.setComputeDevice(cpu, for: .main)
        }
        #endif
    }

    /// Расстояние между отпечатками; `nil`, если их нельзя сравнить (например, разные ревизии из старого кэша).
    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        guard a.elementCount == b.elementCount, a.elementType == b.elementType else { return nil }
        var value: Float = 0
        do {
            try a.computeDistance(&value, to: b)
            return value
        } catch {
            return nil
        }
    }

    /// Резкость: дисперсия лапласиана на уменьшенной копии в оттенках серого.
    /// Чем меньше значение, тем более размыт кадр.
    static func sharpness(_ image: CGImage) -> Double {
        let side = 128
        guard let pixels = grayscale(image, width: side, height: side) else { return 0 }
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0.0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let center = Double(pixels[y * side + x])
                let laplacian = Double(pixels[(y - 1) * side + x]) + Double(pixels[(y + 1) * side + x])
                    + Double(pixels[y * side + x - 1]) + Double(pixels[y * side + x + 1]) - 4 * center
                sum += laplacian
                sumSquares += laplacian * laplacian
                count += 1
            }
        }
        let mean = sum / count
        return sumSquares / count - mean * mean
    }

    /// Разностный хэш 64 бита: одинаковые значения означают практически идентичные картинки.
    static func differenceHash(_ image: CGImage) -> UInt64 {
        guard let pixels = grayscale(image, width: 9, height: 8) else { return 0 }
        var hash: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                hash <<= 1
                if pixels[y * 9 + x] > pixels[y * 9 + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    /// Контраст: стандартное отклонение яркости на копии 32×32 (0…255).
    /// У однотонных кадров (небо, стена, чёрный экран) он близок к нулю, и хэш у них почти одинаковый.
    static func contrast(_ image: CGImage) -> Double {
        let side = 32
        guard let pixels = grayscale(image, width: side, height: side) else { return 0 }
        let values = pixels.map(Double.init)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }

    /// Средние цвета сетки 4×4: 48 байт RGB. Хэш и отпечаток Vision почти не видят цвет,
    /// поэтому одна и та же картинка в синем и фиолетовом варианте иначе считалась бы дублем.
    static func colorSignature(_ image: CGImage) -> [UInt8]? {
        let side = 4
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        return pixels.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
    }

    /// Средняя разница цветовых подписей по каналу (0…255).
    static func colorDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        let total = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(a.count)
    }

    /// Сторона уменьшенной копии в оттенках серого, по которой дубли сравниваются попиксельно.
    static let fineSide = 64
    /// Сторона блока, в котором ищется местное отличие: 4×4 точки, то есть 1/16 ширины кадра.
    static let fineBlock = 4

    /// Яркость кадра 64×64 для точного сравнения копий.
    static func fineSignature(_ image: CGImage) -> [UInt8]? {
        // Высокое качество уменьшения: иначе мелкая текстура даёт разный муар у копий разного размера.
        grayscale(image, width: fineSide, height: fineSide, quality: .high)
    }

    /// Чем отличаются две копии 64×64: средняя разница яркости и разница в самом непохожем блоке 4×4 (0…255).
    /// Общий сдвиг яркости вычитается: пересохранение или другой цветовой профиль меняют весь кадр сразу,
    /// а другое выражение лица или сдвиг камеры меняют отдельные места, и их выдаёт худший блок.
    static func fineDifference(_ a: [UInt8], _ b: [UInt8]) -> (mean: Double, worstBlock: Double) {
        let side = fineSide
        guard a.count == side * side, b.count == a.count else { return (.infinity, .infinity) }
        let sumA = a.reduce(0) { $0 + Int($1) }
        let sumB = b.reduce(0) { $0 + Int($1) }
        let offset = Double(sumA - sumB) / Double(a.count)
        let blocks = side / fineBlock
        var blockSums = [Double](repeating: 0, count: blocks * blocks)
        var total = 0.0
        for y in 0..<side {
            for x in 0..<side {
                let index = y * side + x
                let difference = abs(Double(a[index]) - Double(b[index]) - offset)
                total += difference
                blockSums[(y / fineBlock) * blocks + x / fineBlock] += difference
            }
        }
        let worst = (blockSums.max() ?? 0) / Double(fineBlock * fineBlock)
        return (total / Double(a.count), worst)
    }

    /// Сколько бит отличается у двух хэшей: 0 — одинаковые картинки, до ~6 — почти одинаковые.
    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// Пиксели изображения так, как оно показывается. `UIImage.cgImage` отдаёт битмап без учёта
    /// `imageOrientation`, и повёрнутый кадр получил бы хэш и отпечаток «лежащей» картинки.
    static func uprightCGImage(_ image: UIImage) -> CGImage? {
        guard let cgImage = image.cgImage else { return nil }
        let orientation = image.imageOrientation
        guard orientation != .up else { return cgImage }
        let width = cgImage.width
        let height = cgImage.height
        let rotated: Bool
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: rotated = true
        default: rotated = false
        }
        guard let context = CGContext(
            data: nil,
            width: rotated ? height : width,
            height: rotated ? width : height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return cgImage }
        var transform = CGAffineTransform.identity
        switch orientation {
        case .down, .downMirrored:
            transform = transform.translatedBy(x: CGFloat(width), y: CGFloat(height)).rotated(by: .pi)
        case .left, .leftMirrored:
            transform = transform.translatedBy(x: CGFloat(height), y: 0).rotated(by: .pi / 2)
        case .right, .rightMirrored:
            transform = transform.translatedBy(x: 0, y: CGFloat(width)).rotated(by: -.pi / 2)
        default:
            break
        }
        switch orientation {
        case .upMirrored, .downMirrored, .leftMirrored, .rightMirrored:
            transform = transform.translatedBy(x: CGFloat(width), y: 0).scaledBy(x: -1, y: 1)
        default:
            break
        }
        context.concatenate(transform)
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func grayscale(
        _ image: CGImage,
        width: Int,
        height: Int,
        quality: CGInterpolationQuality = .medium
    ) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = quality
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
