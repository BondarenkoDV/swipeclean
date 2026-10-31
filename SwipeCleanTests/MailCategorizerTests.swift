import XCTest
@testable import SwipeClean

final class MailCategorizerTests: XCTestCase {
    private let boxes = MailboxSet(junk: "Junk", trash: "Deleted Messages")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(mailbox: String = "INBOX", address: String = "friend@example.com", size: Int64 = 10_000, seen: Bool = true, bulk: Bool = false, ageDays: Double = 1) -> MailMessage {
        MailMessage(uid: 1, mailbox: mailbox, senderName: "", senderAddress: address, subject: "x", date: now.addingTimeInterval(-ageDays * 86400), size: size, isSeen: seen, isBulk: bulk)
    }

    func testFoldersWinOverEverything() {
        XCTAssertEqual(MailCategorizer.category(for: message(mailbox: "Junk", bulk: true), boxes: boxes, now: now), .junk)
        XCTAssertEqual(MailCategorizer.category(for: message(mailbox: "Deleted Messages", size: 9_000_000), boxes: boxes, now: now), .trash)
    }

    func testInboxCategories() {
        XCTAssertEqual(MailCategorizer.category(for: message(bulk: true, ageDays: 400), boxes: boxes, now: now), .newsletters)
        XCTAssertEqual(MailCategorizer.category(for: message(size: 6 * 1024 * 1024), boxes: boxes, now: now), .large)
        XCTAssertEqual(MailCategorizer.category(for: message(seen: false, ageDays: 45), boxes: boxes, now: now), .unreadOld)
        XCTAssertNil(MailCategorizer.category(for: message(seen: false, ageDays: 3), boxes: boxes, now: now), "Свежее непрочитанное письмо трогать нельзя")
        XCTAssertNil(MailCategorizer.category(for: message(), boxes: boxes, now: now))
    }

    func testAutomatedSenders() {
        XCTAssertTrue(MailCategorizer.looksAutomated("noreply@shop.example"))
        XCTAssertTrue(MailCategorizer.looksAutomated("no-reply@bank.example"))
        XCTAssertTrue(MailCategorizer.looksAutomated("newsletter.weekly@media.example"))
        XCTAssertFalse(MailCategorizer.looksAutomated("ivan@mail.example"))
        XCTAssertFalse(MailCategorizer.looksAutomated("newsflash"))
    }

    func testDefaultSelectionSkipsRiskyCategories() {
        XCTAssertEqual(MailCategory.defaultSelection, [.junk, .trash, .newsletters])
        XCTAssertTrue(MailCategory.junk.isPermanent)
        XCTAssertFalse(MailCategory.newsletters.isPermanent)
    }
}
