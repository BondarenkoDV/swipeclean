import Photos
import UIKit

/// Отвечает за доступ к медиатеке, следит за статусом разрешения и за изменениями в самой медиатеке.
@MainActor
@Observable
final class PhotoLibraryService: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var status: PHAuthorizationStatus
    /// Растёт после каждого изменения медиатеки (в том числе из других приложений).
    /// Экраны перечитывают данные через `.task(id:)` или `onChange` по этому значению.
    private(set) var changeCount = 0

    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var pendingChange: Task<Void, Never>?

    override init() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
        startObservingIfAllowed()
    }

    var hasAccess: Bool {
        status == .authorized || status == .limited
    }

    var isLimited: Bool {
        status == .limited
    }

    var isDenied: Bool {
        status == .denied || status == .restricted
    }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        startObservingIfAllowed()
    }

    /// Статус мог поменяться в Настройках, пока приложение было в фоне.
    func refreshStatus() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        startObservingIfAllowed()
    }

    private func startObservingIfAllowed() {
        guard hasAccess, !isObserving else { return }
        PHPhotoLibrary.shared().register(self)
        isObserving = true
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.scheduleChange() }
    }

    /// Изменения приходят пачками (iCloud, наши же правки избранного), поэтому сливаем их за полсекунды.
    private func scheduleChange() {
        pendingChange?.cancel()
        pendingChange = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            changeCount += 1
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Системный выбор фото при ограниченном доступе. Показывается поверх верхнего открытого экрана:
    /// если что-то уже показано (лист, полноэкранный просмотр), с корневого контроллера выбор просто не откроется.
    func presentLimitedPicker() {
        guard var top = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController })
            .first else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }
}
