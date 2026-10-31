import Foundation
import Security

/// Одна запись в связке ключей: только на этом устройстве и только пока оно разблокировано.
struct KeychainItem: Sendable {
    let service: String
    let account: String

    /// Имя службы: bundle id приложения и назначение записи, у UI-тестов — своё.
    static func service(_ name: String, uiTesting: Bool) -> String {
        "\(Bundle.main.bundleIdentifier ?? "SwipeClean").\(name)" + (uiTesting ? ".uitest" : "")
    }

    func read() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func save(_ data: Data) {
        delete()
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    func delete() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
