import XCTest
@testable import SwipeClean

final class IMAPParserTests: XCTestCase {
    func testTokenizerHandlesListsQuotedStringsAndLiterals() {
        let header = "From: a@b.c\r\nSubject: Hi\r\n\r\n"
        let raw = "* 12 FETCH (UID 345 RFC822.SIZE 2048 FLAGS (\\Seen \\Flagged) INTERNALDATE \"01-Jan-2026 12:00:00 +0000\" BODY[HEADER.FIELDS (FROM SUBJECT)] {\(header.utf8.count)}\r\n\(header))\r\n"
        let tokens = IMAPParser.tokenize(Data(raw.utf8))
        XCTAssertEqual(tokens.count, 4)
        XCTAssertEqual(tokens[0], .atom("*"))
        XCTAssertEqual(tokens[2], .atom("FETCH"))
        guard case let .list(items) = tokens[3] else { return XCTFail("Ожидался список") }
        XCTAssertEqual(items[0], .atom("UID"))
        XCTAssertEqual(items[1], .atom("345"))
        XCTAssertEqual(items[5], .list([.atom("\\Seen"), .atom("\\Flagged")]))
        XCTAssertEqual(items[7], .string(Data("01-Jan-2026 12:00:00 +0000".utf8)))
        XCTAssertEqual(items[8], .atom("BODY[HEADER.FIELDS (FROM SUBJECT)]"))
        XCTAssertEqual(items[9], .string(Data(header.utf8)))
    }

    func testFetchRecordAndMessage() {
        let header = "From: =?UTF-8?B?0JzQsNCz0LDQt9C40L0=?= <promo@shop.example>\r\nSubject: =?koi8-r?Q?=F0=D2=C9=D7=C5=D4?=\r\nList-Unsubscribe: <mailto:u@shop.example>\r\n\r\n"
        let raw = "* 1 FETCH (UID 77 RFC822.SIZE 6000000 FLAGS () INTERNALDATE \"15-Mar-2026 08:30:00 +0300\" BODY[HEADER.FIELDS (FROM SUBJECT LIST-UNSUBSCRIBE LIST-ID PRECEDENCE)] {\(header.utf8.count)}\r\n\(header))\r\n"
        guard let record = IMAPParser.fetchRecord(from: IMAPParser.tokenize(Data(raw.utf8))) else { return XCTFail("Нет записи FETCH") }
        XCTAssertEqual(record.uid, 77)
        XCTAssertEqual(record.size, 6_000_000)
        XCTAssertNotNil(record.internalDate)
        guard let message = MailMessage(record: record, mailbox: "INBOX") else { return XCTFail("Нет письма") }
        XCTAssertEqual(message.senderName, "Магазин")
        XCTAssertEqual(message.senderAddress, "promo@shop.example")
        XCTAssertEqual(message.subject, "Привет")
        XCTAssertFalse(message.isSeen)
        XCTAssertTrue(message.isBulk)
    }

    func testEncodedWordsJoinWithoutSpaces() {
        XCTAssertEqual(IMAPParser.decodeEncodedWords("=?UTF-8?Q?Hello_=D0=BC=D0=B8=D1=80?= =?UTF-8?Q?!?="), "Hello мир!")
        XCTAssertEqual(IMAPParser.decodeEncodedWords("Plain subject"), "Plain subject")
        XCTAssertEqual(IMAPParser.decodeEncodedWords("Re: =?utf-8?B?0J/RgNC40LLQtdGC?= там"), "Re: Привет там")
    }

    func testSenderParsing() {
        XCTAssertEqual(IMAPParser.sender(from: "\"Ivan Petrov\" <Ivan@Example.com>").name, "Ivan Petrov")
        XCTAssertEqual(IMAPParser.sender(from: "\"Ivan Petrov\" <Ivan@Example.com>").address, "ivan@example.com")
        XCTAssertEqual(IMAPParser.sender(from: "news@example.com").address, "news@example.com")
        XCTAssertEqual(IMAPParser.sender(from: "news@example.com").name, "")
        XCTAssertEqual(IMAPParser.sender(from: "<a@b.c>").address, "a@b.c")
    }

    func testSanitizedStripsControlCharacters() {
        XCTAssertEqual(IMAPParser.sanitized("Hello\u{0007}\r\n  world\t!"), "Hello world !")
    }

    func testHeadersUnfoldContinuationLines() {
        let data = Data("Subject: a very\r\n long subject\r\nFrom: x@y.z\r\nSubject: second\r\n".utf8)
        let headers = IMAPParser.headers(data)
        XCTAssertEqual(headers["subject"], "a very long subject")
        XCTAssertEqual(headers["from"], "x@y.z")
    }

    func testSequenceSetCompressesRanges() {
        XCTAssertEqual(IMAPParser.sequenceSet([5, 1, 2, 3, 9, 10, 7]), "1:3,5,7,9:10")
        XCTAssertEqual(IMAPParser.sequenceSet([4, 4]), "4")
    }

    func testLiteralSizeAndQuoting() {
        XCTAssertEqual(IMAPParser.literalSize(announcedBy: Array("* 1 FETCH (BODY[] {42}\r\n".utf8)), 42)
        XCTAssertNil(IMAPParser.literalSize(announcedBy: Array("* OK done\r\n".utf8)))
        XCTAssertEqual(IMAPParser.quoted("Deleted \"Msgs\""), "\"Deleted \\\"Msgs\\\"\"")
        XCTAssertEqual(IMAPClient.logins(for: " user@icloud.com "), ["user@icloud.com", "user"])
    }

    func testUIDValidityFromSelectResponse() {
        let lines = [
            "* 12 EXISTS\r\n",
            "* OK [PERMANENTFLAGS (\\Seen \\Deleted)] Limited\r\n",
            "* OK [UIDVALIDITY 1424857983] UIDs valid\r\n",
            "* OK [UIDNEXT 4392] Predicted next UID\r\n",
        ]
        let untagged = lines.map { IMAPParser.tokenize(Data($0.utf8)) }
        XCTAssertEqual(IMAPParser.uidValidity(in: untagged), 1_424_857_983)
        XCTAssertNil(IMAPParser.uidValidity(in: [untagged[0], untagged[3]]))
    }

    func testSafeQuotedRejectsLineBreaksAndNul() {
        XCTAssertTrue(IMAPParser.isSafeQuoted("Deleted Messages"))
        XCTAssertTrue(IMAPParser.isSafeQuoted("Папка \"с кавычками\""))
        XCTAssertFalse(IMAPParser.isSafeQuoted("Junk\r\nA9 UID STORE 1:* +FLAGS (\\Deleted)"))
        XCTAssertFalse(IMAPParser.isSafeQuoted("Junk\nA9 NOOP"))
        XCTAssertFalse(IMAPParser.isSafeQuoted("a\u{0}b"))
    }

    func testSearchDateUsesEnglishMonths() {
        var components = DateComponents()
        components.year = 2026
        components.month = 2
        components.day = 3
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(IMAPParser.searchDate(date), "3-Feb-2026")
    }
}
