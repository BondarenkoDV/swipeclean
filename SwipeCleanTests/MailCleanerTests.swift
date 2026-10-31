import XCTest
@testable import SwipeClean

@MainActor
final class MailCleanerTests: XCTestCase {
    private static let suite = "MailCleanerTests"

    /// Между проверкой и чисткой сервер пересоздал папку: UID больше не те, и ничего удаляться не должно.
    func testCleanRefusesWhenMailboxChanged() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        defaults.removePersistentDomain(forName: Self.suite)
        let cleaner = MailCleaner(uiTesting: true, seeded: true, defaults: defaults)
        XCTAssertTrue(cleaner.isConnected)

        cleaner.scan(interval: nil)
        try await wait { cleaner.state == .finished }
        let junkBefore = cleaner.messages(in: .junk).count
        XCTAssertGreaterThan(junkBefore, 0)

        await FakeMailSession.shared.invalidateUIDs()
        await cleaner.clean()

        XCTAssertEqual(cleaner.errorMessage, MailError.mailboxChanged.errorDescription)
        XCTAssertNil(cleaner.report, "Ни одно письмо не должно быть тронуто")
        XCTAssertFalse(cleaner.hasFindings, "Найденное сбрасывается, чтобы проверить заново")
        XCTAssertEqual(cleaner.state, .idle)

        // Повторная проверка видит те же письма: на сервере ничего не удалилось.
        cleaner.scan(interval: nil)
        try await wait { cleaner.state == .finished }
        XCTAssertEqual(cleaner.messages(in: .junk).count, junkBefore)
    }

    /// Проверка за тот же период не начинается заново при каждом открытии экрана, а за другой — начинается.
    func testScanIfNeededReusesResultForSamePeriod() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        defaults.removePersistentDomain(forName: Self.suite)
        let cleaner = MailCleaner(uiTesting: true, seeded: true, defaults: defaults)

        cleaner.scanIfNeeded(interval: nil)
        XCTAssertTrue(cleaner.isScanning)
        try await wait { cleaner.state == .finished }

        cleaner.scanIfNeeded(interval: nil)
        XCTAssertEqual(cleaner.state, .finished, "Тот же период: найденное остаётся")

        let lastMonth = DateInterval(start: .now.addingTimeInterval(-30 * 86400), end: .now)
        cleaner.scanIfNeeded(interval: lastMonth)
        XCTAssertTrue(cleaner.isScanning, "Другой период: проверка начинается заново")
        try await wait { cleaner.state == .finished }
    }

    /// Обрыв связи посреди работы: соединение поднимается заново, и шаг повторяется.
    func testLinkReconnectsAfterDrop() async throws {
        let flaky = FlakySession(drops: 1)
        let link = MailLink(make: { flaky }, email: "test@icloud.com", password: "test-pass")
        let boxes = try await link.run { try await $0.mailboxes() }
        XCTAssertEqual(boxes.junk, "Junk")
        let connects = await flaky.connects
        XCTAssertEqual(connects, 2, "После обрыва должно быть второе подключение")
        await link.close()
    }

    /// Отказ в доступе не лечится повтором: ошибка сразу уходит наверх.
    func testLinkDoesNotRetryAuthenticationFailure() async throws {
        let flaky = FlakySession(drops: 0, rejectLogin: true)
        let link = MailLink(make: { flaky }, email: "test@icloud.com", password: "test-pass")
        do {
            _ = try await link.run { try await $0.mailboxes() }
            XCTFail("Должна быть ошибка входа")
        } catch {
            XCTAssertEqual(error as? MailError, .authenticationFailed)
        }
        let connects = await flaky.connects
        XCTAssertEqual(connects, 1)
    }

    private func wait(timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            guard Date.now < deadline else { return XCTFail("Не дождались состояния за \(timeout) с") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Ящик, у которого рвётся связь: первые `drops` вызовов `mailboxes()` заканчиваются обрывом.
private actor FlakySession: MailSession {
    private var dropsLeft: Int
    private let rejectLogin: Bool
    private(set) var connects = 0

    init(drops: Int, rejectLogin: Bool = false) {
        dropsLeft = drops
        self.rejectLogin = rejectLogin
    }

    func connect(email: String, password: String) async throws {
        connects += 1
        if rejectLogin { throw MailError.authenticationFailed }
    }

    func disconnect() async {}

    func mailboxes() async throws -> MailboxSet {
        if dropsLeft > 0 {
            dropsLeft -= 1
            throw MailError.disconnected
        }
        return MailboxSet(junk: "Junk", trash: "Deleted Messages")
    }

    func quota() async throws -> MailQuota? { nil }
    func search(in mailbox: String, interval: DateInterval?) async throws -> [UInt32] { [] }
    func fetchHeaders(_ uids: [UInt32], in mailbox: String) async throws -> [MailMessage] { [] }
    func uidValidity(of mailbox: String) async throws -> UInt32? { 1 }
    func moveToTrash(_ uids: [UInt32], from mailbox: String, trash: String) async throws {}
    func erase(_ uids: [UInt32], in mailbox: String) async throws {}
}
