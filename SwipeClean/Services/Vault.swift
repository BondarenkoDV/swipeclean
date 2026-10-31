import CryptoKit
import Foundation
import LocalAuthentication
import Photos

/// Файл в секретной папке.
struct VaultItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let fileName: String
    let isVideo: Bool
    /// Когда снято: при возврате в «Фото» дата восстанавливается.
    let creationDate: Date?
    let addedAt: Date
    let size: Int64
}

/// Секретная папка: фото и видео копируются в защищённую папку приложения и закрываются PIN-кодом или Face ID.
/// Файлы лежат с защитой `complete`: пока iPhone заблокирован, их не прочитать даже из резервной копии устройства.
@MainActor
@Observable
final class VaultStore {
    private(set) var items: [VaultItem] = []
    private(set) var isUnlocked = false
    private(set) var hasPasscode: Bool
    /// До какого времени PIN-код не принимается после серии неверных попыток.
    private(set) var lockedUntil: Date?

    let directory: URL
    private let keychain: VaultKeychain
    private let defaults: UserDefaults
    private var failedAttempts: Int

    /// Сколько неверных PIN-кодов подряд можно ввести без паузы.
    nonisolated static let freeAttempts = 5

    init(uiTesting: Bool = SwipeCleanApp.isUITesting, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let base = uiTesting
            ? FileManager.default.temporaryDirectory.appendingPathComponent("vault-uitest", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Vault", isDirectory: true)
        keychain = VaultKeychain(service: KeychainItem.service("vault", uiTesting: uiTesting))
        if uiTesting {
            // Каждый прогон UI-тестов начинается с пустой папки без PIN-кода.
            try? FileManager.default.removeItem(at: base)
            keychain.delete()
            defaults.removeObject(forKey: SettingsKeys.vaultFailedAttempts)
            defaults.removeObject(forKey: SettingsKeys.vaultLockedUntil)
        }
        failedAttempts = defaults.integer(forKey: SettingsKeys.vaultFailedAttempts)
        lockedUntil = defaults.object(forKey: SettingsKeys.vaultLockedUntil) as? Date
        directory = base
        Self.prepare(base)
        hasPasscode = keychain.read() != nil
    }

    /// Создаёт папку с защитой `complete` и убирает её из резервной копии iCloud:
    /// иначе секретные фото уехали бы на сервер.
    private static func prepare(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    func url(for item: VaultItem) -> URL {
        directory.appendingPathComponent(item.fileName)
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    // MARK: - PIN-код и Face ID

    func setPasscode(_ code: String) {
        keychain.save(VaultKeychain.hash(code))
        hasPasscode = true
        unlock()
    }

    /// Проверяет PIN-код и открывает папку. Пока идёт пауза после неверных попыток, любой код отклоняется.
    func unlock(with code: String, now: Date = .now) -> Bool {
        if let lockedUntil, lockedUntil > now { return false }
        guard let stored = keychain.read(), stored == VaultKeychain.hash(code) else {
            failedAttempts += 1
            lockedUntil = Self.lockout(afterFailures: failedAttempts).map { now.addingTimeInterval($0) }
            saveAttempts()
            return false
        }
        unlock()
        return true
    }

    /// Пауза после неверного кода: первые попытки без неё, затем 30 с и вдвое дольше за каждую следующую ошибку,
    /// но не больше часа. Четыре цифры — это 10 000 вариантов: без паузы их можно перебрать за вечер.
    nonisolated static func lockout(afterFailures failures: Int) -> TimeInterval? {
        guard failures >= freeAttempts else { return nil }
        return min(30 * pow(2, Double(min(failures - freeAttempts, 10))), 3600)
    }

    private func saveAttempts() {
        defaults.set(failedAttempts, forKey: SettingsKeys.vaultFailedAttempts)
        defaults.set(lockedUntil, forKey: SettingsKeys.vaultLockedUntil)
    }

    /// Face ID или Touch ID, если они настроены на устройстве.
    var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    func unlockWithBiometrics() async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
        let reason = String(localized: "Открыть секретную папку")
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) == true else {
            return false
        }
        unlock()
        return true
    }

    func lock() {
        isUnlocked = false
        items = []
    }

    /// Удаляет PIN-код и всё содержимое папки.
    func erase() {
        try? FileManager.default.removeItem(at: directory)
        // Новая папка снова без резервной копии: флаг исключения жил на удалённой.
        Self.prepare(directory)
        keychain.delete()
        hasPasscode = false
        failedAttempts = 0
        lockedUntil = nil
        saveAttempts()
        lock()
    }

    private func unlock() {
        isUnlocked = true
        items = loadIndex()
        failedAttempts = 0
        lockedUntil = nil
        saveAttempts()
    }

    // MARK: - Содержимое

    /// Копирует фото и видео из медиатеки в папку. Оригиналы не трогает: их удаление — отдельный шаг.
    /// Возвращает идентификаторы ассетов, которые удалось скопировать.
    func importAssets(_ assets: [PHAsset]) async -> [String] {
        guard isUnlocked else { return [] }
        let directory = directory
        var imported: [String] = []
        for asset in assets {
            if Task.isCancelled { break }
            guard let item = await Self.copy(asset, into: directory) else { continue }
            items.append(item)
            imported.append(asset.localIdentifier)
            saveIndex()
        }
        return imported
    }

    /// Возвращает файлы в «Фото» с исходной датой и убирает их из папки.
    func restoreToLibrary(_ selected: [VaultItem]) async throws {
        let entries = selected.map { (url: url(for: $0), isVideo: $0.isVideo, date: $0.creationDate) }
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            for entry in entries {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: entry.isVideo ? .video : .photo, fileURL: entry.url, options: nil)
                request.creationDate = entry.date
            }
        }
        delete(selected)
    }

    func delete(_ selected: [VaultItem]) {
        let ids = Set(selected.map(\.id))
        for item in selected {
            try? FileManager.default.removeItem(at: url(for: item))
        }
        items.removeAll { ids.contains($0.id) }
        saveIndex()
    }

    private func loadIndex() -> [VaultItem] {
        guard let data = try? Data(contentsOf: indexURL),
              let items = try? JSONDecoder().decode([VaultItem].self, from: data) else { return [] }
        // Файл могли потерять (например, при восстановлении без папки): такие записи не показываем.
        return items.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: [.atomic, .completeFileProtection])
    }

    /// Пишет основной ресурс ассета (с правками, если они есть) в файл папки.
    private nonisolated static func copy(_ asset: PHAsset, into directory: URL) async -> VaultItem? {
        let resources = PHAssetResource.assetResources(for: asset)
        let isVideo = asset.mediaType == .video
        let preferred: [PHAssetResourceType] = isVideo ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        guard let resource = preferred.lazy.compactMap({ type in resources.first { $0.type == type } }).first else { return nil }
        let id = UUID()
        let ext = (resource.originalFilename as NSString).pathExtension
        let fileName = id.uuidString + (ext.isEmpty ? (isVideo ? ".mov" : ".jpg") : "." + ext.lowercased())
        let url = directory.appendingPathComponent(fileName)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        return VaultItem(id: id, fileName: fileName, isVideo: isVideo, creationDate: asset.creationDate, addedAt: .now, size: size)
    }
}

/// Хэш PIN-кода в связке ключей: только на этом устройстве и только пока оно разблокировано.
struct VaultKeychain: Sendable {
    private let item: KeychainItem

    init(service: String) {
        item = KeychainItem(service: service, account: "passcode")
    }

    static func hash(_ code: String) -> Data {
        Data(SHA256.hash(data: Data(("swipeclean-vault:" + code).utf8)))
    }

    func read() -> Data? { item.read() }
    func save(_ data: Data) { item.save(data) }
    func delete() { item.delete() }
}
