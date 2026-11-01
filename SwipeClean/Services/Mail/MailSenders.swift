import Foundation
import SwiftUI

/// Отправитель и все его письма во «Входящих» за выбранный период.
struct MailSender: Identifiable, Equatable, Sendable {
    /// Адрес в нижнем регистре: по нему письма и собираются.
    let address: String
    /// Имя из самого свежего письма, где оно указано.
    let name: String
    /// Письма отправителя, новые первыми.
    let messages: [MailMessage]
    let size: Int64
    /// Больше половины писем — рассылки или автоматические уведомления.
    let isBulk: Bool

    var id: String { address }
    var count: Int { messages.count }
    var latest: Date { messages.first?.date ?? .distantPast }

    /// Имя, а если его нет ни в одном письме — адрес.
    var displayName: String {
        name.isEmpty ? address : name
    }

    /// Буква для кружка: первая буква или цифра имени.
    var initial: String {
        displayName.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "@"
    }

    /// Постоянный цвет кружка: один и тот же отправитель всегда одного цвета.
    var tone: Tone {
        let sum = address.unicodeScalars.reduce(UInt(0)) { $0 &+ UInt($1.value) }
        return Tone.allCases[Int(sum % UInt(Tone.allCases.count))]
    }
}

/// Порядок списка отправителей. Выбор запоминается.
enum MailSenderSort: String, CaseIterable, Identifiable, Sendable {
    case count
    case size
    case recent
    case name

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .count: "Больше писем"
        case .size: "Больше места"
        case .recent: "Сначала недавние"
        case .name: "По имени"
        }
    }

    /// При равенстве решает число писем, затем адрес, чтобы строки не прыгали между пересчётами.
    func sorted(_ senders: [MailSender]) -> [MailSender] {
        senders.sorted { a, b in
            switch self {
            case .count where a.count != b.count:
                return a.count > b.count
            case .size where a.size != b.size:
                return a.size > b.size
            case .recent where a.latest != b.latest:
                return a.latest > b.latest
            case .name:
                let order = a.displayName.localizedStandardCompare(b.displayName)
                if order != .orderedSame { return order == .orderedAscending }
            default:
                break
            }
            if a.count != b.count { return a.count > b.count }
            return a.address < b.address
        }
    }
}

/// Сборка писем по отправителям. Чистые функции, проверяются модульными тестами.
enum MailSenderGrouper {
    /// Группирует письма по адресу отправителя. Письма без адреса собираются по имени.
    /// Результат: больше всего писем — первыми.
    static func group(_ messages: [MailMessage]) -> [MailSender] {
        let groups = Dictionary(grouping: messages) { key(for: $0) }
        let senders = groups.map { address, messages -> MailSender in
            let sorted = messages.sorted { $0.date != $1.date ? $0.date > $1.date : $0.uid > $1.uid }
            let bulk = sorted.filter(\.isBulk).count
            return MailSender(
                address: address,
                name: sorted.first { !$0.senderName.isEmpty }?.senderName ?? "",
                messages: sorted,
                size: sorted.reduce(0) { $0 + $1.size },
                isBulk: bulk * 2 > sorted.count
            )
        }
        return MailSenderSort.count.sorted(senders)
    }

    /// Ключ группы: адрес в нижнем регистре, а без адреса — имя.
    static func key(for message: MailMessage) -> String {
        let address = message.senderAddress.trimmingCharacters(in: .whitespaces).lowercased()
        return address.isEmpty ? message.senderName.lowercased() : address
    }

    /// Поиск по имени и адресу без учёта регистра и диакритики.
    static func matches(_ sender: MailSender, query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return sender.name.range(of: text, options: options) != nil
            || sender.address.range(of: text, options: options) != nil
    }
}
