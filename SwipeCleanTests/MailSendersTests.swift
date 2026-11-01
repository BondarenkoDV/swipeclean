import XCTest
@testable import SwipeClean

final class MailSenderGrouperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(_ uid: UInt32, _ name: String, _ address: String, days: Double, size: Int64 = 1000, bulk: Bool = false) -> MailMessage {
        MailMessage(uid: uid, mailbox: "INBOX", senderName: name, senderAddress: address, subject: "Тема \(uid)",
                    date: now.addingTimeInterval(-days * 86400), size: size, isSeen: true, isBulk: bulk)
    }

    /// Письма собираются по адресу без учёта регистра, имя берётся из свежего письма, где оно есть.
    func testGroupsByAddressNewestNameFirst() {
        let senders = MailSenderGrouper.group([
            message(1, "Магазин", "shop@example.com", days: 10, size: 100),
            message(2, "", "SHOP@example.com", days: 1, size: 200),
            message(3, "Магазин Плюс", "shop@example.com", days: 3, size: 300, bulk: true),
            message(4, "Друг", "friend@example.com", days: 2, size: 5000),
        ])
        XCTAssertEqual(senders.map(\.id), ["shop@example.com", "friend@example.com"], "Больше писем — первым")
        let shop = senders[0]
        XCTAssertEqual(shop.count, 3)
        XCTAssertEqual(shop.size, 600)
        XCTAssertEqual(shop.name, "Магазин Плюс", "Имя из самого свежего письма, где оно указано")
        XCTAssertEqual(shop.messages.map(\.uid), [2, 3, 1], "Новые письма первыми")
        XCTAssertFalse(shop.isBulk, "Рассылка — только если рассылок больше половины")
        XCTAssertEqual(shop.initial, "М")
    }

    /// Без адреса письма собираются по имени, а без имени показывается адрес.
    func testFallbacksWithoutNameOrAddress() {
        let senders = MailSenderGrouper.group([
            message(1, "Без адреса", "", days: 1),
            message(2, "Без адреса", "", days: 2),
            message(3, "", "robot@example.com", days: 3, bulk: true),
        ])
        XCTAssertEqual(senders.first?.id, "без адреса")
        XCTAssertEqual(senders.first?.count, 2)
        let robot = senders[1]
        XCTAssertEqual(robot.displayName, "robot@example.com")
        XCTAssertTrue(robot.isBulk)
        XCTAssertEqual(robot.initial, "R")
    }

    func testSortOrders() {
        let senders = MailSenderGrouper.group([
            message(1, "Бета", "b@example.com", days: 1, size: 10),
            message(2, "Бета", "b@example.com", days: 9, size: 10),
            message(3, "Альфа", "a@example.com", days: 5, size: 900),
            message(4, "Гамма", "g@example.com", days: 0.5, size: 50),
        ])
        XCTAssertEqual(MailSenderSort.count.sorted(senders).map(\.id), ["b@example.com", "a@example.com", "g@example.com"])
        XCTAssertEqual(MailSenderSort.size.sorted(senders).map(\.id), ["a@example.com", "g@example.com", "b@example.com"])
        XCTAssertEqual(MailSenderSort.recent.sorted(senders).map(\.id), ["g@example.com", "b@example.com", "a@example.com"])
        XCTAssertEqual(MailSenderSort.name.sorted(senders).map(\.id), ["a@example.com", "b@example.com", "g@example.com"])
    }

    func testSearchMatchesNameAndAddress() {
        let sender = MailSenderGrouper.group([message(1, "Озон", "news@ozon.example", days: 1)])[0]
        XCTAssertTrue(MailSenderGrouper.matches(sender, query: "озон"))
        XCTAssertTrue(MailSenderGrouper.matches(sender, query: "OZON"))
        XCTAssertTrue(MailSenderGrouper.matches(sender, query: " "))
        XCTAssertFalse(MailSenderGrouper.matches(sender, query: "wildberries"))
    }

    /// Цвет кружка не зависит от запуска: тот же адрес — тот же цвет.
    func testToneIsStable() {
        let first = MailSenderGrouper.group([message(1, "", "a@example.com", days: 1)])[0]
        let second = MailSenderGrouper.group([message(2, "Другое имя", "a@example.com", days: 2)])[0]
        XCTAssertEqual(first.tone, second.tone)
    }
}

@MainActor
final class MailSendersCleanTests: XCTestCase {
    private static let suite = "MailSendersCleanTests"
    private static let store = "orders@test-store.example"

    /// Всё от отправителя уходит в «Удалённые», кроме снятого с чистки письма;
    /// письма отправителя-рассылки пропадают и из категории.
    func testCleanSendersMovesOnlyActiveMessages() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        defaults.removePersistentDomain(forName: Self.suite)
        let cleaner = MailCleaner(uiTesting: true, seeded: true, defaults: defaults)

        cleaner.scan(interval: nil)
        try await wait { cleaner.state == .finished }
        let store = try XCTUnwrap(cleaner.sender(Self.store))
        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(store.name, "Тест Магазин")
        XCTAssertEqual(cleaner.senders.first?.id, Self.store, "Больше всего писем — первым")
        XCTAssertTrue(cleaner.inbox.allSatisfy { $0.mailbox == "INBOX" }, "Отправители строятся только по «Входящим»")

        let kept = store.messages[0]
        cleaner.toggle(kept)
        XCTAssertEqual(cleaner.active(from: store).count, 2)
        await cleaner.cleanSenders([Self.store])
        XCTAssertNil(cleaner.errorMessage)
        XCTAssertEqual(cleaner.report, MailCleaner.Report(count: 2, freed: 0, moved: store.messages.dropFirst().reduce(0) { $0 + $1.size }))
        XCTAssertEqual(cleaner.sender(Self.store)?.messages.map(\.id), [kept.id], "Снятое с чистки письмо остаётся")
        XCTAssertEqual(cleaner.state, .finished)

        let newsletters = cleaner.messages(in: .newsletters).count
        let shop = try XCTUnwrap(cleaner.sender("newsletter@test-shop.example"))
        await cleaner.cleanSenders([shop.id])
        XCTAssertNil(cleaner.sender(shop.id))
        XCTAssertEqual(cleaner.messages(in: .newsletters).count, newsletters - 1, "Письмо ушло и из категории рассылок")

        // На сервере остались только снятые с чистки письма.
        cleaner.scan(interval: nil)
        try await wait { cleaner.state == .finished }
        XCTAssertEqual(cleaner.sender(Self.store)?.count, 1)
        XCTAssertNil(cleaner.sender(shop.id))
    }

    /// Чистка категорий тоже убирает ушедшие письма из списка отправителей.
    func testCategoryCleanUpdatesSenders() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite + ".categories"))
        defaults.removePersistentDomain(forName: Self.suite + ".categories")
        let cleaner = MailCleaner(uiTesting: true, seeded: true, defaults: defaults)
        cleaner.scan(interval: nil)
        try await wait { cleaner.state == .finished }
        let large = try XCTUnwrap(cleaner.messages(in: .large).first)
        XCTAssertNotNil(cleaner.sender(large.senderAddress))

        for category in MailCategory.allCases { cleaner.setSelected(category, category == .large) }
        await cleaner.clean()
        XCTAssertNil(cleaner.errorMessage)
        XCTAssertNil(cleaner.sender(large.senderAddress), "Тяжёлое письмо ушло — его отправитель пропал из списка")
    }

    private func wait(timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            guard Date.now < deadline else { return XCTFail("Не дождались состояния за \(timeout) с") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
