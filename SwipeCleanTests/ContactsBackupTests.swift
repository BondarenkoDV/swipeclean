import Contacts
import UIKit
import XCTest
@testable import SwipeClean

final class ContactsBackupTests: XCTestCase {
    private func entry(_ id: String, _ role: ContactsBackup.Role, hasImage: Bool = false) -> ContactsBackup.Entry {
        ContactsBackup.Entry(id: id, name: id, role: role, hasImage: hasImage, container: nil)
    }

    /// Маленькая картинка с пикселями, чтобы фото было настоящим JPEG.
    private func jpeg() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }

    /// Фото контакта, если поле загружено: чтение незагруженного поля роняет приложение.
    private func image(_ contact: CNContact?) -> Data? {
        guard let contact, contact.isKeyAvailable(CNContactImageDataKey) else { return nil }
        return contact.imageData
    }

    private func contact(_ given: String, phones: [String], image: Data? = nil) -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = given
        contact.phoneNumbers = phones.map { CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0)) }
        contact.imageData = image
        return contact
    }

    // MARK: - План восстановления

    func testRestorePlanRevertsKeptAndReaddsMissing() {
        let actions = ContactsRestorePlan.actions(
            for: [
                entry("kept", .kept),
                entry("gone", .removed),
                entry("back", .removed),
                entry("keptGone", .kept),
                entry("snapHere", .snapshot),
                entry("snapGone", .snapshot),
            ],
            existing: ["kept", "back", "snapHere"]
        )
        XCTAssertEqual(actions, [.update("kept"), .add, .skip, .add, .skip, .add])
    }

    // MARK: - Сколько копий хранить

    func testRetentionKeepsNewestOfEachKind() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let operations = (0..<(ContactsBackupRetention.operationLimit + 3)).map { index in
            ContactsBackup(date: start.addingTimeInterval(Double(index)), kind: index.isMultiple(of: 2) ? .merge : .delete, entries: [])
        }
        let full = (0..<(ContactsBackupRetention.fullLimit + 2)).map { index in
            ContactsBackup(date: start.addingTimeInterval(Double(index) * 10), kind: .full, entries: [])
        }
        let split = ContactsBackupRetention.split(operations + full)
        XCTAssertEqual(split.keep.filter { $0.kind != .full }.count, ContactsBackupRetention.operationLimit)
        XCTAssertEqual(split.keep.filter { $0.kind == .full }.count, ContactsBackupRetention.fullLimit)
        XCTAssertEqual(split.drop.count, 5)
        // Уходят самые старые, а список идёт от новых к старым.
        XCTAssertEqual(Set(split.drop.filter { $0.kind != .full }.map(\.id)), Set(operations.prefix(3).map(\.id)))
        XCTAssertEqual(split.keep.map(\.date), split.keep.map(\.date).sorted(by: >))
    }

    // MARK: - vCard

    func testVCardKeepsNamePhoneAndPhoto() throws {
        let photo = try jpeg()
        let source = [contact("Анна", phones: ["+7 900 111-22-33"], image: photo), contact("Борис", phones: ["8 900 000 00 01"])]
        let data = try ContactsVCard.data(for: source, photos: [photo, nil])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let cards = ContactsVCard.cards(in: text)
        XCTAssertEqual(cards.count, 2)
        XCTAssertNotNil(ContactsVCard.photo(in: cards[0]))
        XCTAssertNil(ContactsVCard.photo(in: cards[1]))

        let restored = try ContactsVCard.contacts(from: data)
        XCTAssertEqual(restored.map(\.givenName), ["Анна", "Борис"])
        XCTAssertEqual(restored.first?.phoneNumbers.first?.value.stringValue, "+7 900 111-22-33")
        XCTAssertNotNil(image(restored.first))
        XCTAssertNil(image(restored.last))
    }

    func testFoldedPhotoLineIsReadBack() throws {
        let photo = Data((0..<200).map { UInt8($0) })
        let card = "BEGIN:VCARD\r\nVERSION:3.0\r\nN:;Анна;;;\r\nEND:VCARD\r\n"
        let withPhoto = ContactsVCard.insertingPhoto(photo, into: card)
        // Строки не длиннее 75 символов, продолжения начинаются с пробела.
        for line in withPhoto.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.count, 75, line)
        }
        XCTAssertTrue(withPhoto.hasPrefix("BEGIN:VCARD"))
        XCTAssertEqual(ContactsVCard.photo(in: withPhoto), photo)
        XCTAssertEqual(ContactsVCard.cards(in: withPhoto + withPhoto).count, 2)
    }

    func testPhotoLinksAreNotFetched() {
        let card = "BEGIN:VCARD\nVERSION:3.0\nPHOTO;VALUE=uri:https://example.com/a.jpg\nEND:VCARD\n"
        XCTAssertNil(ContactsVCard.photo(in: card))
        let inline = "BEGIN:VCARD\nVERSION:4.0\nPHOTO:data:image/png;base64,AAEC\nEND:VCARD\n"
        XCTAssertEqual(ContactsVCard.photo(in: inline), Data([0, 1, 2]))
    }

    /// Отмена объединения: основной контакт теряет добавленные номера и чужое фото, имя и номер из копии остаются.
    func testRestoreFieldsUndoMerge() throws {
        let before = contact("Мама", phones: ["+7 900 000-00-01"])
        let backup = try XCTUnwrap(ContactsVCard.contacts(from: ContactsVCard.data(for: [before], photos: [nil])).first)

        let merged = contact("Мама", phones: ["+7 900 000-00-01", "+7 900 000-00-02"], image: try jpeg())
        merged.organizationName = "Работа"
        ContactsVCard.restoreFields(of: merged, from: backup, hadImage: false)
        XCTAssertEqual(merged.givenName, "Мама")
        XCTAssertEqual(merged.phoneNumbers.map(\.value.stringValue), ["+7 900 000-00-01"])
        XCTAssertEqual(merged.organizationName, "")
        XCTAssertNil(image(merged))
    }

    // MARK: - Список копий на диске

    @MainActor
    func testStoreKeepsListAcrossLaunchesAndDeletesFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ContactsBackupStore(directory: directory)
        XCTAssertTrue(store.items.isEmpty)
        let older = ContactsBackup(date: Date(timeIntervalSince1970: 1_000), kind: .delete, entries: [entry("a", .removed)])
        let newer = ContactsBackup(date: Date(timeIntervalSince1970: 2_000), kind: .merge, entries: [entry("b", .kept), entry("c", .removed)])
        for backup in [older, newer] {
            try Data("BEGIN:VCARD\r\nEND:VCARD\r\n".utf8).write(to: store.fileURL(for: backup))
            store.add(backup)
        }
        XCTAssertEqual(store.items.map(\.id), [newer.id, older.id])
        XCTAssertTrue(store.fileURL(for: newer).lastPathComponent.hasSuffix(".vcf"))

        let reopened = ContactsBackupStore(directory: directory)
        XCTAssertEqual(reopened.items, store.items)

        reopened.delete(older)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.fileURL(for: older).path))
        // Копия, у которой пропал файл, в списке не показывается.
        try FileManager.default.removeItem(at: reopened.fileURL(for: newer))
        XCTAssertTrue(ContactsBackupStore(directory: directory).items.isEmpty)
    }
}
