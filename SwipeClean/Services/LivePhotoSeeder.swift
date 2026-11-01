#if DEBUG
import AVFoundation
import CoreGraphics
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Тестовые Live Photos для UI-тестов (запуск с `-uiTesting -seedLivePhotos`). Симулятор не снимает
/// Live Photos, поэтому пара «снимок + видео» собирается здесь: у обоих один идентификатор содержимого
/// (в MakerApple снимка и в метаданных QuickTime видео), по нему PhotoKit и склеивает их в одно Live Photo.
/// В Release-сборку не попадает.
enum LivePhotoSeeder {
    enum SeedError: Error, CustomStringConvertible {
        case image
        case video(String)

        var description: String {
            switch self {
            case .image: "не удалось записать снимок"
            case let .video(reason): "не удалось записать видео: \(reason)"
            }
        }
    }

    /// `SwipeCleanApp` — тип главного актора, поэтому и проверка флага на нём.
    @MainActor static var isRequested: Bool {
        SwipeCleanApp.isUITesting && ProcessInfo.processInfo.arguments.contains("-seedLivePhotos")
    }

    @MainActor private static var didSeed = false

    /// Один раз за запуск добавляет Live Photos, пока их не станет `count`.
    /// Возвращает текст ошибки, чтобы тест показал причину, а не просто пустой экран.
    @MainActor
    static func seedOnce(count: Int = 2) async -> String? {
        guard isRequested, !didSeed else { return nil }
        didSeed = true
        do {
            try await ensure(count: count)
            return nil
        } catch {
            return "Тестовые Live Photos: \(error)"
        }
    }

    static func ensure(count: Int) async throws {
        let existing = PHAsset.fetchAssets(with: LivePhotoConverter.fetchOptions()).count
        guard existing < count else { return }
        for _ in existing..<count {
            try await addLivePhoto()
        }
    }

    private static func addLivePhoto() async throws {
        let identifier = UUID().uuidString
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-seed-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appendingPathComponent("IMG_LIVE.JPG")
        let videoURL = folder.appendingPathComponent("IMG_LIVE.MOV")

        guard let image = makeImage(width: 1600, height: 1200) else { throw SeedError.image }
        try writeImage(image, identifier: identifier, to: imageURL)
        try await writeVideo(of: image, identifier: identifier, to: videoURL)

        // Случайный день 2017–2020 годов: снимки не попадают в «Похожие» друг к другу (те ищутся в пределах
        // 10 минут) и не мешают тестам умной чистки за недавний период.
        let date = Date(timeIntervalSince1970: 1_490_000_000 + Double.random(in: 0..<110_000_000))
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: imageURL, options: nil)
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
            request.creationDate = date
        }
    }

    // MARK: - Снимок

    /// Случайные чёткие прямоугольники и круги: каждый снимок уникален (не дубль прошлого прогона)
    /// и резкий (не попадает в «Размытые»).
    private static func makeImage(width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        func randomColor() -> CGColor {
            CGColor(srgbRed: CGFloat.random(in: 0...1), green: CGFloat.random(in: 0...1), blue: CGFloat.random(in: 0...1), alpha: 1)
        }
        context.setFillColor(randomColor())
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for index in 0..<60 {
            context.setFillColor(randomColor())
            let rect = CGRect(
                x: Double.random(in: 0..<Double(width)), y: Double.random(in: 0..<Double(height)),
                width: Double.random(in: 40...400), height: Double.random(in: 40...400)
            )
            if index.isMultiple(of: 3) {
                context.fillEllipse(in: rect)
            } else {
                context.fill(rect)
            }
        }
        return context.makeImage()
    }

    /// JPEG с идентификатором содержимого Live Photo в MakerApple (ключ 17).
    private static func writeImage(_ image: CGImage, identifier: String, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw SeedError.image
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: ["17": identifier],
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SeedError.image }
    }

    // MARK: - Видео

    private static let fps: Int32 = 15
    private static let frameCount: Int32 = 30
    private static let videoWidth = 640
    private static let videoHeight = 480

    /// Двухсекундный ролик со снимком и бегущей полосой. В метаданных — тот же идентификатор содержимого
    /// и отметка кадра-снимка (still-image-time), как у ролика, который снимает камера iPhone.
    private static func writeVideo(of image: CGImage, identifier: String, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
        ])
        videoInput.expectsMediaDataInRealTime = false
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight,
        ])
        writer.add(videoInput)
        writer.metadata = [contentIdentifier(identifier)]
        let stillTime = stillImageTimeAdaptor()
        stillTime.assetWriterInput.expectsMediaDataInRealTime = false
        writer.add(stillTime.assetWriterInput)

        guard writer.startWriting() else {
            throw SeedError.video(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        // Отметка кадра-снимка до кадров видео, пока входы пустые: так делает и запись Live Photo камерой.
        let range = CMTimeRange(start: CMTime(value: CMTimeValue(frameCount / 2), timescale: fps), duration: CMTime(value: 1, timescale: fps))
        guard stillTime.append(AVTimedMetadataGroup(items: [stillImageTime()], timeRange: range)) else {
            throw SeedError.video(writer.error?.localizedDescription ?? "still-image-time")
        }
        stillTime.assetWriterInput.markAsFinished()

        for frame in 0..<frameCount {
            try await waitUntilReady(videoInput, writer: writer)
            guard let buffer = pixelBuffer(pool: pixels.pixelBufferPool, image: image, frame: Int(frame)) else {
                throw SeedError.video("pixel buffer")
            }
            guard pixels.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
                throw SeedError.video(writer.error?.localizedDescription ?? "append")
            }
        }
        videoInput.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { @Sendable in continuation.resume() }
        }
        guard writer.status == .completed else {
            throw SeedError.video(writer.error?.localizedDescription ?? "finishWriting")
        }
    }

    /// Ждёт, пока вход примет следующий кадр; если запись встала, бросает ошибку, а не висит.
    private static func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed || Date() > deadline {
                throw SeedError.video(writer.error?.localizedDescription ?? "writer stalled")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func pixelBuffer(pool: CVPixelBufferPool?, image: CGImage, frame: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        } else {
            CVPixelBufferCreate(kCFAllocatorDefault, videoWidth, videoHeight, kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: CVPixelBufferGetBaseAddress(buffer),
                  width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        context.draw(image, in: bounds)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8))
        let step = bounds.width / CGFloat(frameCount)
        context.fill(CGRect(x: CGFloat(frame) * step, y: 0, width: step * 2, height: bounds.height))
        return buffer
    }

    private static func contentIdentifier(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = "com.apple.quicktime.content.identifier" as NSString
        item.value = identifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    private static func stillImageTime() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = "com.apple.quicktime.still-image-time" as NSString
        item.value = NSNumber(value: Int8(0))
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        return item
    }

    private static func stillImageTimeAdaptor() -> AVAssetWriterInputMetadataAdaptor {
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String,
        ]
        var description: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &description
        )
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }
}
#endif
