import XCTest
@testable import SwipeClean

/// Gmail рядом с iCloud: свой сервер и логин, свои имена папок, общие категории и общая чистка.
@MainActor
final class GmailTests: XCTestCase {
    private static let suite = "GmailTests"

    // MARK: - Сервис

    func testServersAndLogins() {
        XCTAssertEqual(MailProvider.icloud.host, "imap.mail.me.com")
        XCTAssertEqual(MailProvider.gmail.host, "imap.gmail.com")
        XCTAssertEqual(MailProvider.gmail.port, 993)
        // Gmail принимает только полный адрес: вторая попытка с именем без домена — лишний неудачный вход.
        XCTAssertEqual(MailProvider.gmail.logins(for: " user@gmail.com "), ["user@gmail.com"])
        XCTAssertEqual(MailProvider.icloud.logins(for: "user@icloud.com"), ["user@icloud.com", "user"])
    }

    /// Google показывает пароль приложения группами через пробел: пробелы не часть пароля.
    /// У Apple дефисы — часть пароля, их трогать нельзя.
    func testAppPasswordNormalization() {
        XCTAssertEqual(MailProvider.gmail.normalizedPassword(" abcd efgh ijkl mnop\n"), "abcdefghijklmnop")
        XCTAssertEqual(MailProvider.gmail.normalizedPassword("abcd\u{00A0}efgh\u{00A0}ijkl\u{00A0}mnop"), "abcdefghijklmnop")
        XCTAssertEqual(MailProvider.icloud.normalizedPassword(" abcd-efgh-ijkl-mnop "), "abcd-efgh-ijkl-mnop")
    }

    /// Ошибка входа объясняет, где взять пароль приложения именно этого сервиса.
    func testAuthenticationMessageNamesService() {
        XCTAssertTrue(MailError.authenticationFailed.message(for: .gmail).contains("myaccount.google.com/apppasswords"))
        XCTAssertTrue(MailError.authenticationFailed.message(for: .icloud).contains("account.apple.com"))
        XCTAssertTrue(MailError.connectionFailed.message(for: .gmail).contains("Gmail"))
        XCTAssertEqual(MailError.mailboxChanged.errorDescription, MailError.mailboxChanged.message(for: .icloud))
    }

    // MARK: - Папки

    /// Gmail отмечает спам и корзину атрибутами SPECIAL-USE, а узел «[Gmail]» нельзя выбрать.
    func testGmailFoldersFromSpecialUse() {
        let lines = [
            "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n",
            "* LIST (\\HasChildren \\Noselect) \"/\" \"[Gmail]\"\r\n",
            "* LIST (\\All \\HasNoChildren) \"/\" \"[Gmail]/All Mail\"\r\n",
            "* LIST (\\HasNoChildren \\Junk) \"/\" \"[Gmail]/&BCEEPwQwBDw-\"\r\n",
            "* LIST (\\HasNoChildren \\Trash) \"/\" \"[Gmail]/&BBoEPgRABDcEOAQ9BDA-\"\r\n",
            "* LIST (\\HasNoChildren \\Sent) \"/\" \"[Gmail]/Sent Mail\"\r\n",
        ]
        let boxes = IMAPClient.mailboxSet(from: lines.map { IMAPParser.tokenize(Data($0.utf8)) })
        XCTAssertEqual(boxes.junk, "[Gmail]/&BCEEPwQwBDw-", "Русский «Спам» в modified UTF-7")
        XCTAssertEqual(boxes.trash, "[Gmail]/&BBoEPgRABDcEOAQ9BDA-", "Русская «Корзина» в modified UTF-7")
        XCTAssertEqual(boxes.all, ["[Gmail]/&BCEEPwQwBDw-", "[Gmail]/&BBoEPgRABDcEOAQ9BDA-", "INBOX"])
    }

    /// Без атрибутов папки находятся по именам, в том числе «[Google Mail]» и британская «Bin».
    func testGmailFoldersByName() {
        let lines = [
            "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n",
            "* LIST (\\HasNoChildren) \"/\" \"[Google Mail]/Spam\"\r\n",
            "* LIST (\\HasNoChildren) \"/\" \"[Google Mail]/Bin\"\r\n",
        ]
        let boxes = IMAPClient.mailboxSet(from: lines.map { IMAPParser.tokenize(Data($0.utf8)) })
        XCTAssertEqual(boxes.junk, "[Google Mail]/Spam")
        XCTAssertEqual(boxes.trash, "[Google Mail]/Bin")
    }

    /// У iCloud папки по-прежнему находятся по именам.
    func testICloudFoldersByName() {
        let lines = [
            "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n",
            "* LIST (\\HasNoChildren) \"/\" \"Junk\"\r\n",
            "* LIST (\\HasNoChildren) \"/\" \"Deleted Messages\"\r\n",
        ]
        let boxes = IMAPClient.mailboxSet(from: lines.map { IMAPParser.tokenize(Data($0.utf8)) })
        XCTAssertEqual(boxes.junk, "Junk")
        XCTAssertEqual(boxes.trash, "Deleted Messages")
    }

    // MARK: - Два ящика

    /// Одинаковые папка и UID в разных ящиках — разные письма.
    func testMessageIDsDifferBetweenAccounts() {
        let message = MailMessage(uid: 7, mailbox: "INBOX", senderName: "", senderAddress: "a@b.c", subject: "", date: .now, size: 1, isSeen: true, isBulk: false)
        XCTAssertNotEqual(message.id, message.tagged(.gmail).id)
        XCTAssertEqual(message.tagged(.gmail).account, .gmail)
    }

    /// Оба ящика проверяются вместе: категории общие, письма не путаются, одна чистка убирает лишнее из обоих.
    func testScanAndCleanBothAccounts() async throws {
        let defaults = try freshDefaults()
        let icloud = FakeMailSession(provider: .icloud)
        let gmail = FakeMailSession(provider: .gmail)
        let cleaner = MailCleaner(uiTesting: true, seeded: true, seededGmail: true, defaults: defaults, makeSession: { $0 == .gmail ? gmail : icloud })
        XCTAssertEqual(cleaner.accounts.map(\.provider), [.icloud, .gmail])
        XCTAssertTrue(cleaner.accountsTitle.contains("iCloud Mail"))
        XCTAssertTrue(cleaner.accountsTitle.contains("Gmail"))

        cleaner.scan(interval: nil)
        try await wait { cleaner.state == .finished }
        XCTAssertNil(cleaner.errorMessage)
        let junk = cleaner.messages(in: .junk)
        XCTAssertEqual(junk.count, 5, "Спам: 3 из iCloud и 2 из Gmail")
        XCTAssertEqual(junk.filter { $0.account == .gmail }.count, 2)
        XCTAssertEqual(Set(junk.map(\.id)).count, junk.count, "UID в ящиках совпадают, но id должны различаться")
        XCTAssertEqual(cleaner.messages(in: .trash).count, 3)
        XCTAssertEqual(cleaner.messages(in: .newsletters).count, 3)
        XCTAssertNotNil(cleaner.quota(for: .gmail))
        // По умолчанию: спам, удалённые и рассылки. iCloud 3 + 2 + 2, Gmail 2 + 1 + 1.
        XCTAssertEqual(cleaner.selectedCount, 11)

        await cleaner.clean()
        XCTAssertNil(cleaner.errorMessage)
        XCTAssertEqual(cleaner.report?.count, 11)
        XCTAssertTrue(cleaner.messages(in: .junk).isEmpty)

        // На серверах обоих ящиков спам и корзина пусты, а рассылки переехали в корзину своего ящика.
        let gmailSpam = await gmail.search(in: "[Gmail]/Spam", interval: nil)
        let gmailTrash = await gmail.search(in: "[Gmail]/Trash", interval: nil)
        let icloudSpam = await icloud.search(in: "Junk", interval: nil)
        let icloudTrash = await icloud.search(in: "Deleted Messages", interval: nil)
        XCTAssertTrue(gmailSpam.isEmpty)
        XCTAssertTrue(icloudSpam.isEmpty)
        XCTAssertEqual(gmailTrash.count, 1, "Рассылка Gmail в корзине Gmail")
        XCTAssertEqual(icloudTrash.count, 2, "Рассылки iCloud в «Удалённых» iCloud")
    }

    /// Gmail не пустил: найденное в iCloud всё равно показывается, а ошибка называет ящик.
    func testFailingAccountKeepsOtherResults() async throws {
        let defaults = try freshDefaults()
        let icloud = FakeMailSession(provider: .icloud)
        let rejecting = RejectingSession()
        let cleaner = MailCleaner(uiTesting: true, seeded: true, seededGmail: true, defaults: defaults,
                                  makeSession: { provider -> any MailSession in provider == .gmail ? rejecting : icloud })

        cleaner.scan(interval: nil)
        try await wait { cleaner.state == .finished }
        XCTAssertEqual(cleaner.messages(in: .junk).count, 3)
        XCTAssertTrue(cleaner.messages(in: .junk).allSatisfy { $0.account == .icloud })
        let error = try XCTUnwrap(cleaner.errorMessage)
        XCTAssertTrue(error.hasPrefix("Gmail:"), error)
        XCTAssertTrue(error.contains("myaccount.google.com/apppasswords"), error)
    }

    /// Новый ящик добавляется к подключённому, а отключение одного не трогает другой.
    func testSignInAndOutKeepsOtherAccount() async throws {
        let defaults = try freshDefaults()
        let icloud = FakeMailSession(provider: .icloud)
        let gmail = FakeMailSession(provider: .gmail)
        let cleaner = MailCleaner(uiTesting: true, seeded: true, defaults: defaults, makeSession: { $0 == .gmail ? gmail : icloud })
        XCTAssertEqual(cleaner.availableProviders, [.gmail])

        do {
            try await cleaner.signIn(provider: .gmail, email: "me@gmail.com", password: "wrong")
            XCTFail("Неверный пароль должен отклоняться")
        } catch {
            XCTAssertEqual(error as? MailError, .authenticationFailed)
        }
        XCTAssertEqual(cleaner.accounts.count, 1)

        try await cleaner.signIn(provider: .gmail, email: " me@gmail.com ", password: "abcd efgh ijkl mnop")
        XCTAssertEqual(cleaner.accounts.map(\.provider), [.icloud, .gmail])
        XCTAssertEqual(cleaner.account(.gmail)?.email, "me@gmail.com")
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.gmailAccount), "me@gmail.com")

        cleaner.scan(interval: nil)
        try await wait { cleaner.state == .finished }
        XCTAssertEqual(cleaner.messages(in: .junk).count, 5)

        cleaner.signOut(.gmail)
        XCTAssertEqual(cleaner.accounts.map(\.provider), [.icloud])
        XCTAssertFalse(cleaner.hasFindings, "Письма отключённого ящика не должны остаться в списках")
        XCTAssertNil(defaults.string(forKey: SettingsKeys.gmailAccount))
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.mailAccount), "test@icloud.com")
    }

    // MARK: - Помощники

    private func freshDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        defaults.removePersistentDomain(forName: Self.suite)
        return defaults
    }

    private func wait(timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            guard Date.now < deadline else { return XCTFail("Не дождались состояния за \(timeout) с") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Ящик, который не принимает пароль.
private actor RejectingSession: MailSession {
    func connect(email: String, password: String) async throws { throw MailError.authenticationFailed }
    func disconnect() async {}
    func mailboxes() async throws -> MailboxSet { MailboxSet() }
    func quota() async throws -> MailQuota? { nil }
    func search(in mailbox: String, interval: DateInterval?) async throws -> [UInt32] { [] }
    func fetchHeaders(_ uids: [UInt32], in mailbox: String) async throws -> [MailMessage] { [] }
    func uidValidity(of mailbox: String) async throws -> UInt32? { 1 }
    func moveToTrash(_ uids: [UInt32], from mailbox: String, trash: String) async throws {}
    func erase(_ uids: [UInt32], in mailbox: String) async throws {}
}
