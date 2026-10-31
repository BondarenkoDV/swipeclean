import UIKit

/// Держит приложение в рабочем состоянии, пока идёт долгая работа с сетью (проверка или чистка почты):
/// экран не гаснет сам, а если уйти в другое приложение, система даёт ещё немного времени дописать текущую порцию.
/// Если связь всё же оборвётся, работа переподключится и продолжит, когда приложение снова откроют.
@MainActor
final class KeepAwake {
    /// Сколько работ сейчас держат экран: он снова может гаснуть, только когда закончится последняя.
    private static var holders = 0

    private var task: UIBackgroundTaskIdentifier = .invalid
    private var isActive = true

    init(name: String) {
        Self.holders += 1
        UIApplication.shared.isIdleTimerDisabled = true
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
    }

    func end() {
        guard isActive else { return }
        isActive = false
        Self.holders = max(0, Self.holders - 1)
        if Self.holders == 0 {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
