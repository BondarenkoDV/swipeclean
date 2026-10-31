#if DEBUG
import Foundation

/// Поддельный почтовый ящик для UI-тестов: без сети, с предсказуемым набором писем.
/// Один на процесс, чтобы удалённые письма не возвращались при следующем сканировании.
actor FakeMailSession: MailSession {
    static let shared = FakeMailSession()
    static let junkName = "Junk"
    static let trashName = "Deleted Messages"

    private var boxes: [String: [MailMessage]] = FakeMailSession.seed()
    private var nextUID: UInt32 = 1000
    private var validity: UInt32 = 1

    func connect(email: String, password: String) async throws {
        guard password != "wrong" else { throw MailError.authenticationFailed }
    }

    func disconnect() {}

    func mailboxes() -> MailboxSet {
        MailboxSet(junk: Self.junkName, trash: Self.trashName)
    }

    func quota() -> MailQuota? {
        MailQuota(used: 2_300_000_000, limit: 5_368_709_120)
    }

    func search(in mailbox: String, interval: DateInterval?) -> [UInt32] {
        (boxes[mailbox] ?? [])
            .filter { interval?.contains($0.date) ?? true }
            .map(\.uid)
    }

    func fetchHeaders(_ uids: [UInt32], in mailbox: String) -> [MailMessage] {
        let wanted = Set(uids)
        return (boxes[mailbox] ?? []).filter { wanted.contains($0.uid) }
    }

    func uidValidity(of mailbox: String) -> UInt32? {
        validity
    }

    /// Имитирует пересоздание папок на сервере: все старые UID перестают быть надёжными.
    func invalidateUIDs() {
        validity += 1
    }

    func moveToTrash(_ uids: [UInt32], from mailbox: String, trash: String) {
        let wanted = Set(uids)
        let moved = (boxes[mailbox] ?? []).filter { wanted.contains($0.uid) }
        boxes[mailbox]?.removeAll { wanted.contains($0.uid) }
        for message in moved {
            nextUID += 1
            boxes[trash, default: []].append(MailMessage(
                uid: nextUID, mailbox: trash, senderName: message.senderName, senderAddress: message.senderAddress,
                subject: message.subject, date: message.date, size: message.size, isSeen: message.isSeen, isBulk: message.isBulk
            ))
        }
    }

    func erase(_ uids: [UInt32], in mailbox: String) {
        let wanted = Set(uids)
        boxes[mailbox]?.removeAll { wanted.contains($0.uid) }
    }

    private static func seed() -> [String: [MailMessage]] {
        let now = Date.now
        func days(_ count: Int) -> Date { now.addingTimeInterval(-Double(count) * 86400) }
        func message(_ uid: UInt32, _ mailbox: String, _ name: String, _ address: String, _ subject: String, _ date: Date, size: Int64 = 24_000, seen: Bool = true, bulk: Bool = false) -> MailMessage {
            MailMessage(uid: uid, mailbox: mailbox, senderName: name, senderAddress: address, subject: subject, date: date, size: size, isSeen: seen, isBulk: bulk)
        }
        return [
            junkName: [
                message(1, junkName, "Тест Спам", "win@test-spam.example", "Вы выиграли приз", days(2), seen: false, bulk: true),
                message(2, junkName, "Тест Спам", "promo@test-spam.example", "Срочно подтвердите аккаунт", days(9), seen: false),
                message(3, junkName, "", "noreply@test-spam.example", "Ваш заказ ждёт оплаты", days(20), seen: false, bulk: true),
            ],
            trashName: [
                message(10, trashName, "Тест Удалённое", "old@test-mail.example", "Старое письмо", days(40)),
                message(11, trashName, "Тест Удалённое", "old@test-mail.example", "Ещё одно старое письмо", days(70), size: 300_000),
            ],
            "INBOX": [
                message(20, "INBOX", "Тест Рассылка", "newsletter@test-shop.example", "Скидки недели", days(3), size: 180_000, bulk: true),
                message(21, "INBOX", "Тест Рассылка", "news@test-shop.example", "Новинки сезона", days(15), size: 210_000, seen: false, bulk: true),
                message(22, "INBOX", "Тест Тяжёлое", "friend@test-mail.example", "Фото с поездки", days(30), size: 8_500_000),
                message(23, "INBOX", "Тест Непрочитанное", "someone@test-mail.example", "Напоминание", days(60), seen: false),
                message(24, "INBOX", "Тест Обычное", "boss@test-mail.example", "Планы на неделю", days(1)),
                message(25, "INBOX", "Тест Обычное", "mom@test-mail.example", "Приезжай на выходных", days(5), seen: false),
            ],
        ]
    }
}
#endif
