#if DEBUG
import Foundation

/// Поддельный почтовый ящик для UI-тестов: без сети, с предсказуемым набором писем.
/// Один на сервис и процесс, чтобы удалённые письма не возвращались при следующем сканировании.
actor FakeMailSession: MailSession {
    static let shared = FakeMailSession(provider: .icloud)
    static let gmail = FakeMailSession(provider: .gmail)

    static func session(for provider: MailProvider) -> FakeMailSession {
        provider == .gmail ? gmail : shared
    }

    private let junkName: String
    private let trashName: String
    private var boxes: [String: [MailMessage]]
    private var nextUID: UInt32 = 1000
    private var validity: UInt32 = 1

    init(provider: MailProvider) {
        let junk = provider == .gmail ? "[Gmail]/Spam" : "Junk"
        let trash = provider == .gmail ? "[Gmail]/Trash" : "Deleted Messages"
        junkName = junk
        trashName = trash
        boxes = provider == .gmail ? Self.gmailSeed(junk: junk, trash: trash) : Self.icloudSeed(junk: junk, trash: trash)
    }

    func connect(email: String, password: String) async throws {
        guard password != "wrong" else { throw MailError.authenticationFailed }
    }

    func disconnect() {}

    func mailboxes() -> MailboxSet {
        MailboxSet(junk: junkName, trash: trashName)
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

    private static func message(_ uid: UInt32, _ mailbox: String, _ name: String, _ address: String, _ subject: String, daysAgo: Int, size: Int64 = 24_000, seen: Bool = true, bulk: Bool = false) -> MailMessage {
        let date = Date.now.addingTimeInterval(-Double(daysAgo) * 86400)
        return MailMessage(uid: uid, mailbox: mailbox, senderName: name, senderAddress: address, subject: subject, date: date, size: size, isSeen: seen, isBulk: bulk)
    }

    /// iCloud: спам 3, удалённые 2, рассылки 2, тяжёлое 1, старое непрочитанное 1, два обычных письма
    /// и три письма одного магазина для списка отправителей.
    private static func icloudSeed(junk: String, trash: String) -> [String: [MailMessage]] {
        [
            junk: [
                message(1, junk, "Тест Спам", "win@test-spam.example", "Вы выиграли приз", daysAgo: 2, seen: false, bulk: true),
                message(2, junk, "Тест Спам", "promo@test-spam.example", "Срочно подтвердите аккаунт", daysAgo: 9, seen: false),
                message(3, junk, "", "noreply@test-spam.example", "Ваш заказ ждёт оплаты", daysAgo: 20, seen: false, bulk: true),
            ],
            trash: [
                message(10, trash, "Тест Удалённое", "old@test-mail.example", "Старое письмо", daysAgo: 40),
                message(11, trash, "Тест Удалённое", "old@test-mail.example", "Ещё одно старое письмо", daysAgo: 70, size: 300_000),
            ],
            "INBOX": [
                message(20, "INBOX", "Тест Рассылка", "newsletter@test-shop.example", "Скидки недели", daysAgo: 3, size: 180_000, bulk: true),
                message(21, "INBOX", "Тест Рассылка", "news@test-shop.example", "Новинки сезона", daysAgo: 15, size: 210_000, seen: false, bulk: true),
                message(22, "INBOX", "Тест Тяжёлое", "friend@test-mail.example", "Фото с поездки", daysAgo: 30, size: 8_500_000),
                message(23, "INBOX", "Тест Непрочитанное", "someone@test-mail.example", "Напоминание", daysAgo: 60, seen: false),
                message(24, "INBOX", "Тест Обычное", "boss@test-mail.example", "Планы на неделю", daysAgo: 1),
                message(25, "INBOX", "Тест Обычное", "mom@test-mail.example", "Приезжай на выходных", daysAgo: 5, seen: false),
                // Обычные письма одного отправителя: ни в одну категорию не попадают, видны только в списке отправителей.
                message(26, "INBOX", "Тест Магазин", "orders@test-store.example", "Ваш заказ отправлен", daysAgo: 2, size: 40_000),
                message(27, "INBOX", "Тест Магазин", "orders@test-store.example", "Заказ доставлен", daysAgo: 6, size: 60_000),
                message(28, "INBOX", "Тест Магазин", "orders@test-store.example", "Оцените покупку", daysAgo: 12, size: 50_000),
            ],
        ]
    }

    /// Gmail: спам 2, корзина 1, рассылка 1 и обычное письмо. UID те же, что у iCloud: так тесты ловят
    /// путаницу между ящиками.
    private static func gmailSeed(junk: String, trash: String) -> [String: [MailMessage]] {
        [
            junk: [
                message(1, junk, "Тест Gmail Спам", "prize@test-gspam.example", "Заберите бонус", daysAgo: 4, seen: false, bulk: true),
                message(2, junk, "Тест Gmail Спам", "alert@test-gspam.example", "Аккаунт будет заблокирован", daysAgo: 12, seen: false),
            ],
            trash: [
                message(10, trash, "Тест Gmail Корзина", "old@test-gmail.example", "Удалённое письмо", daysAgo: 25),
            ],
            "INBOX": [
                message(20, "INBOX", "Тест Gmail Рассылка", "newsletter@test-gshop.example", "Распродажа", daysAgo: 6, size: 150_000, bulk: true),
                message(24, "INBOX", "Тест Gmail Обычное", "friend@test-gmail.example", "Встретимся в субботу", daysAgo: 2),
            ],
        ]
    }
}
#endif
