import Foundation
import SwiftUI

/// Письмо в том виде, в каком его знает приложение: только заголовочные данные.
/// Текст письма, ссылки и вложения не загружаются никогда — этого достаточно, чтобы решить, нужно ли оно.
struct MailMessage: Identifiable, Hashable, Sendable {
    let uid: UInt32
    let mailbox: String
    let senderName: String
    let senderAddress: String
    let subject: String
    /// Когда письмо пришло на сервер.
    let date: Date
    let size: Int64
    let isSeen: Bool
    /// Рассылка или автоматическое письмо: есть List-Unsubscribe, List-Id или Precedence: bulk.
    let isBulk: Bool
    /// Ящик, из которого письмо: у iCloud и Gmail одинаковые имена папок и пересекающиеся UID.
    private(set) var account: MailProvider

    var id: String { "\(account.rawValue):\(mailbox)#\(uid)" }

    /// Имя отправителя, а если его нет — адрес.
    var displaySender: String {
        senderName.isEmpty ? senderAddress : senderName
    }

    var displaySubject: String {
        subject.isEmpty ? String(localized: "Без темы") : subject
    }

    init(uid: UInt32, mailbox: String, senderName: String, senderAddress: String, subject: String, date: Date, size: Int64, isSeen: Bool, isBulk: Bool, account: MailProvider = .icloud) {
        self.uid = uid
        self.mailbox = mailbox
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.subject = subject
        self.date = date
        self.size = size
        self.isSeen = isSeen
        self.isBulk = isBulk
        self.account = account
    }

    /// То же письмо с пометкой ящика, из которого оно пришло.
    func tagged(_ account: MailProvider) -> MailMessage {
        var copy = self
        copy.account = account
        return copy
    }

    /// Собирает письмо из ответа FETCH. Без UID письмо бесполезно: его не удалить.
    init?(record: IMAPFetchRecord, mailbox: String) {
        guard let uid = record.uid else { return nil }
        let headers = record.header.map(IMAPParser.headers) ?? [:]
        let sender = IMAPParser.sender(from: headers["from"] ?? "")
        let precedence = headers["precedence"]?.lowercased() ?? ""
        self.init(
            uid: uid,
            mailbox: mailbox,
            senderName: sender.name,
            senderAddress: sender.address,
            subject: IMAPParser.sanitized(IMAPParser.decodeEncodedWords(headers["subject"] ?? "")),
            date: record.internalDate ?? .now,
            size: record.size ?? 0,
            isSeen: record.flags.contains { $0.caseInsensitiveCompare("\\Seen") == .orderedSame },
            isBulk: headers["list-unsubscribe"] != nil || headers["list-id"] != nil
                || ["bulk", "list", "junk"].contains(precedence)
                || MailCategorizer.looksAutomated(sender.address)
        )
    }
}

/// Папки ящика: входящие есть всегда, спам и удалённые находятся по атрибутам LIST или по имени.
struct MailboxSet: Sendable, Equatable {
    let inbox = "INBOX"
    var junk: String?
    var trash: String?

    var all: [String] { [junk, trash, inbox].compactMap { $0 } }
}

/// Сколько места занято на сервере почты. Gmail может отдавать всё хранилище аккаунта Google, а не только почту.
struct MailQuota: Sendable, Equatable {
    let used: Int64
    let limit: Int64

    var fraction: Double { limit > 0 ? Double(used) / Double(limit) : 0 }
}

/// Категории лишних писем. Спам и удалённые стираются насовсем, остальное переезжает в корзину ящика
/// («Удалённые» у iCloud, «Корзина» у Gmail), откуда письмо можно вернуть.
enum MailCategory: String, CaseIterable, Identifiable, Sendable {
    case junk
    case trash
    case newsletters
    case large
    case unreadOld

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .junk: "Спам"
        case .trash: "Удалённые"
        case .newsletters: "Рассылки и реклама"
        case .large: "Тяжёлые письма"
        case .unreadOld: "Старые непрочитанные"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .junk: "Папка «Спам» целиком"
        case .trash: "Папка «Удалённые» (в Gmail — «Корзина») целиком"
        case .newsletters: "Письма с кнопкой «Отписаться» и автоматические уведомления"
        case .large: "Письма от 5 МБ: обычно с вложениями"
        case .unreadOld: "Не открыты больше 30 дней"
        }
    }

    var symbol: String {
        switch self {
        case .junk: "xmark.bin.fill"
        case .trash: "trash.fill"
        case .newsletters: "megaphone.fill"
        case .large: "paperclip"
        case .unreadOld: "envelope.badge.fill"
        }
    }

    var tone: Tone {
        switch self {
        case .junk: .red
        case .trash: .orange
        case .newsletters: .pink
        case .large: .indigo
        case .unreadOld: .teal
        }
    }

    /// Стирается насовсем: письма из этих папок и так на пути в никуда.
    var isPermanent: Bool {
        self == .junk || self == .trash
    }

    /// Что произойдёт с письмами при чистке.
    var actionHint: LocalizedStringKey {
        isPermanent ? "Удалятся навсегда" : "Переедут в корзину почты"
    }

    /// Включено по умолчанию: то, что безопасно убирать не глядя.
    var isDefaultSelected: Bool {
        self != .large && self != .unreadOld
    }

    static let defaultSelection: Set<MailCategory> = Set(allCases.filter(\.isDefaultSelected))
}

/// Правила распределения писем по категориям. Чистые функции, проверяются модульными тестами.
enum MailCategorizer {
    static let largeThreshold: Int64 = 5 * 1024 * 1024
    static let unreadAge: TimeInterval = 30 * 86400

    private static let automatedPrefixes = ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "newsletter", "news", "promo", "marketing", "mailer", "notifications", "notification", "digest", "bounce"]

    /// Автоматический отправитель по адресу: noreply@, newsletter@ и похожие.
    static func looksAutomated(_ address: String) -> Bool {
        guard let at = address.firstIndex(of: "@") else { return false }
        let local = address[..<at].lowercased()
        return automatedPrefixes.contains { local == $0 || local.hasPrefix($0 + ".") || local.hasPrefix($0 + "-") || local.hasPrefix($0 + "_") }
    }

    /// Категория письма, или `nil`, если письмо обычное и трогать его не надо.
    static func category(for message: MailMessage, boxes: MailboxSet, now: Date = .now) -> MailCategory? {
        if let junk = boxes.junk, message.mailbox == junk { return .junk }
        if let trash = boxes.trash, message.mailbox == trash { return .trash }
        if message.isBulk { return .newsletters }
        if message.size >= largeThreshold { return .large }
        if !message.isSeen, now.timeIntervalSince(message.date) > unreadAge { return .unreadOld }
        return nil
    }
}
