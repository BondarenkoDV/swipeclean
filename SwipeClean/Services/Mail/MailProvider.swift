import Foundation
import SwiftUI

/// Почтовый сервис, который можно подключить. Оба работают по IMAP с паролем приложения: его создают
/// один раз у Apple или Google, он подходит только для почты и отзывается в любой момент. OAuth не нужен.
enum MailProvider: String, CaseIterable, Identifiable, Sendable {
    case icloud
    case gmail

    var id: String { rawValue }

    /// Сервер IMAP. Других адресов клиент не знает: пароль уходит только сюда.
    var host: String {
        switch self {
        case .icloud: "imap.mail.me.com"
        case .gmail: "imap.gmail.com"
        }
    }

    var port: UInt16 { 993 }

    /// Название сервиса. Имя собственное, поэтому не переводится.
    var title: String {
        switch self {
        case .icloud: "iCloud Mail"
        case .gmail: "Gmail"
        }
    }

    /// Короткое имя для сообщений об ошибках: «Не удалось подключиться к Gmail».
    var serverName: String {
        switch self {
        case .icloud: "iCloud"
        case .gmail: "Gmail"
        }
    }

    var symbol: String {
        switch self {
        case .icloud: "icloud.fill"
        case .gmail: "envelope.fill"
        }
    }

    var tone: Tone {
        switch self {
        case .icloud: .blue
        case .gmail: .red
        }
    }

    var emailPlaceholder: String {
        switch self {
        case .icloud: "name@icloud.com"
        case .gmail: "name@gmail.com"
        }
    }

    /// Как выглядит пароль приложения у этого сервиса.
    var passwordPlaceholder: String {
        switch self {
        case .icloud: "xxxx-xxxx-xxxx-xxxx"
        case .gmail: "xxxx xxxx xxxx xxxx"
        }
    }

    /// Страница, где создают пароли приложений.
    var appPasswordsURL: URL? {
        switch self {
        case .icloud: URL(string: "https://account.apple.com/account/manage/section/security")
        case .gmail: URL(string: "https://myaccount.google.com/apppasswords")
        }
    }

    /// Сайт, где пароль приложения можно отозвать.
    var accountSite: String {
        switch self {
        case .icloud: "account.apple.com"
        case .gmail: "myaccount.google.com"
        }
    }

    /// Запись в связке ключей. У iCloud прежнее имя, чтобы подключённая раньше почта не отвалилась после обновления.
    var keychainAccount: String { rawValue }

    /// Где хранится адрес ящика. У iCloud прежний ключ по той же причине.
    var accountKey: String {
        switch self {
        case .icloud: SettingsKeys.mailAccount
        case .gmail: SettingsKeys.gmailAccount
        }
    }

    /// Имена для LOGIN по порядку. Apple советует имя без домена, но многие ящики iCloud принимают только
    /// полный адрес, поэтому пробуем оба. Gmail принимает только полный адрес, а лишняя неудачная попытка
    /// входа у Google только приближает временную блокировку.
    func logins(for email: String) -> [String] {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .icloud:
            guard let at = trimmed.firstIndex(of: "@") else { return [trimmed] }
            return [trimmed, String(trimmed[..<at])]
        case .gmail:
            return [trimmed]
        }
    }

    /// Пароль в том виде, в каком его ждёт сервер. Google показывает пароль приложения четырьмя группами
    /// через пробел («abcd efgh ijkl mnop»), а пробелы в нём только для удобства чтения: убираем все.
    /// У Apple дефисы — часть пароля, поэтому там срезаются только пробелы по краям.
    func normalizedPassword(_ value: String) -> String {
        switch self {
        case .icloud: value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .gmail: value.filter { !$0.isWhitespace }
        }
    }
}
