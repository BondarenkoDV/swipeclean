import AVFoundation
import Photos
import UIKit

/// Загрузка превью и полноразмерных изображений с кэшем PhotoKit.
/// Фото из iCloud подгружаются по сети, прогресс отдаётся через колбэк.
/// Отмена задачи SwiftUI отменяет и запрос в PhotoKit: быстрые свайпы не копят лишние загрузки.
@MainActor
final class AssetImageLoader {
    static let shared = AssetImageLoader()

    private let manager = PHCachingImageManager()

    /// Размер карточки в пикселях: весь экран. Сама карточка меньше, но запрос и предзагрузка
    /// должны совпадать по размеру, иначе кэш PhotoKit не срабатывает.
    let cardTargetSize: CGSize

    private init() {
        manager.allowsCachingHighQualityImages = true
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first ?? UIScreen.main
        cardTargetSize = CGSize(
            width: screen.bounds.width * screen.scale,
            height: screen.bounds.height * screen.scale
        )
    }

    func image(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        if let onProgress {
            // Колбэки PhotoKit приходят с его очередей, поэтому они `@Sendable` и не привязаны к главному актору.
            options.progressHandler = { @Sendable progress, _, _, _ in
                onProgress(progress)
            }
        }
        let manager = manager
        return await PhotoKitRequest<UIImage>(manager: manager).run { finish in
            manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { @Sendable image, _ in
                finish(image)
            }
        }
    }

    func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        let manager = manager
        return await PhotoKitRequest<AVPlayerItem>(manager: manager).run { finish in
            manager.requestPlayerItem(forVideo: asset, options: options) { @Sendable item, _ in
                finish(item)
            }
        }
    }

    func livePhoto(for asset: PHAsset, targetSize: CGSize) async -> PHLivePhoto? {
        let options = PHLivePhotoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        let manager = manager
        return await PhotoKitRequest<PHLivePhoto>(manager: manager).run { finish in
            manager.requestLivePhoto(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { @Sendable photo, _ in
                finish(photo)
            }
        }
    }

    func startCaching(_ assets: [PHAsset], targetSize: CGSize) {
        manager.startCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFill, options: nil)
    }

    func stopCaching(_ assets: [PHAsset], targetSize: CGSize) {
        manager.stopCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFill, options: nil)
    }
}

/// Результат PhotoKit, переданный из его потока в задачу. PhotoKit отдаёт объект и больше его не трогает,
/// поэтому передача владения безопасна, хотя сами UIImage, AVPlayerItem и PHLivePhoto не помечены Sendable.
private struct Delivery<Value>: @unchecked Sendable {
    let value: Value?
}

/// Связывает запрос PhotoKit с задачей Swift: отмена задачи отменяет запрос,
/// а продолжение завершается ровно один раз, даже если отмена пришла раньше идентификатора запроса.
/// Изменяемое состояние защищено замком, поэтому класс можно передавать между потоками.
private final class PhotoKitRequest<Value>: @unchecked Sendable {
    private let manager: PHImageManager
    private let lock = NSLock()
    private var requestID: PHImageRequestID?
    private var continuation: CheckedContinuation<Delivery<Value>, Never>?
    private var isCancelled = false

    init(manager: PHImageManager) {
        self.manager = manager
    }

    /// `start` делает запрос и получает колбэк завершения, который можно вызвать с любого потока.
    /// Запрос стартует в изоляции вызывающего (обычно главный актор), поэтому `start` никуда не передаётся.
    /// `withCheckedContinuation` без параметра isolation тоже выполняется в этой изоляции.
    func run(
        isolation: isolated (any Actor)? = #isolation,
        _ start: (@escaping @Sendable (Value?) -> Void) -> PHImageRequestID
    ) async -> Value? {
        let delivery = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Delivery<Value>, Never>) in
                lock.lock()
                if isCancelled {
                    lock.unlock()
                    continuation.resume(returning: Delivery(value: nil))
                    return
                }
                self.continuation = continuation
                lock.unlock()

                let id = start { [self] value in
                    self.finish(with: value)
                }

                lock.lock()
                requestID = id
                let cancelledMeanwhile = isCancelled
                lock.unlock()
                if cancelledMeanwhile {
                    manager.cancelImageRequest(id)
                }
            }
        } onCancel: {
            cancel()
        }
        return delivery.value
    }

    private func finish(with value: Value?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: Delivery(value: value))
    }

    private func cancel() {
        lock.lock()
        isCancelled = true
        let id = requestID
        lock.unlock()
        if let id {
            manager.cancelImageRequest(id)
        }
        // PhotoKit после отмены вызывает обработчик с nil, но на всякий случай завершаем сами.
        finish(with: nil)
    }
}
