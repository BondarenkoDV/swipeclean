import SwiftUI

/// Ключи UserDefaults для настроек приложения.
enum SettingsKeys {
    static let onboardingCompleted = "onboardingCompleted"
    static let hapticsEnabled = "hapticsEnabled"
    static let videoSoundEnabled = "videoSoundEnabled"
    static let swapHorizontalSwipes = "swapHorizontalSwipes"
    static let appearance = "appearance"
    static let smartCleanPeriod = "smartCleanPeriod"
    static let compressionLevel = "compressionLevel"
    static let deleteOriginalsAfterCompression = "deleteOriginalsAfterCompression"
    static let mediaSortOrder = "mediaSortOrder"
    static let vaultBiometrics = "vaultBiometrics"
    static let vaultFailedAttempts = "vaultFailedAttempts"
    static let vaultLockedUntil = "vaultLockedUntil"
    static let eventAge = "eventAge"
    static let mailAccount = "mailAccount"
    static let gmailAccount = "gmailAccount"
    static let mailPeriod = "mailPeriod"
    static let mailCategories = "mailCategories"
    static let mailSenderSort = "mailSenderSort"
    static let reminderEnabled = "reminderEnabled"
    /// Время напоминания в минутах от полуночи.
    static let reminderMinutes = "reminderMinutes"
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "Как в системе")
        case .light: String(localized: "Светлая")
        case .dark: String(localized: "Тёмная")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
