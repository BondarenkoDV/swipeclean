import XCTest
@testable import SwipeClean

final class ContactsAnalysisTests: XCTestCase {
    private func card(_ id: String, _ name: String, phones: [String] = [], emails: [String] = [], organization: String = "") -> ContactCard {
        ContactCard(id: id, name: name, organization: organization, phones: phones, emails: emails)
    }

    func testPhoneIgnoresFormattingAndCountryCode() {
        XCTAssertEqual(ContactsAnalysis.normalizedPhone("+7 (900) 111-22-33"), "9001112233")
        XCTAssertEqual(ContactsAnalysis.normalizedPhone("8 900 111 22 33"), "9001112233")
        // Короткие служебные номера не сравниваем: «112» у разных людей не делает их дублями.
        XCTAssertNil(ContactsAnalysis.normalizedPhone("112"))
    }

    func testNameIgnoresCaseSpacesAndDiacritics() {
        XCTAssertEqual(ContactsAnalysis.normalizedName("Ёлкин  Пётр"), ContactsAnalysis.normalizedName("елкин петр"))
        XCTAssertNil(ContactsAnalysis.normalizedName("   "))
    }

    func testSameNameOrPhoneOrEmailMakesOneGroup() {
        let groups = ContactsAnalysis.duplicateGroups([
            card("a", "Анна Иванова"),
            card("b", "анна иванова", phones: ["+7 900 111-22-33"]),
            card("c", "Аня", phones: ["89001112233"]),
            card("d", "Пётр", emails: ["Petr@Mail.ru"]),
            card("e", "Пётр Петров", emails: ["petr@mail.ru "]),
            card("f", "Иван"),
        ])
        XCTAssertEqual(groups.count, 2)
        // a и b совпали по имени, b и c по телефону: все трое в одной группе.
        let anna = groups.first { $0.contains { $0.id == "a" } }
        XCTAssertEqual(Set(anna?.map(\.id) ?? []), ["a", "b", "c"])
        let petr = groups.first { $0.contains { $0.id == "d" } }
        XCTAssertEqual(Set(petr?.map(\.id) ?? []), ["d", "e"])
    }

    func testRichestContactComesFirst() {
        let groups = ContactsAnalysis.duplicateGroups([
            card("empty", "Мама"),
            card("full", "Мама", phones: ["+7 900 000-00-01", "+7 900 000-00-02"], emails: ["mama@example.com"]),
        ])
        XCTAssertEqual(groups.first?.first?.id, "full")
    }

    func testDifferentPeopleAreNotGrouped() {
        let groups = ContactsAnalysis.duplicateGroups([
            card("a", "Анна", phones: ["+7 900 000-00-01"]),
            card("b", "Борис", phones: ["+7 900 000-00-02"]),
        ])
        XCTAssertTrue(groups.isEmpty)
    }

    func testIncompleteMeansNoPhoneAndNoEmail() {
        XCTAssertTrue(card("a", "Анна").isIncomplete)
        XCTAssertFalse(card("b", "Борис", emails: ["b@example.com"]).isIncomplete)
        XCTAssertTrue(card("c", "", phones: ["+7 900 000-00-01"]).hasNoName)
        XCTAssertFalse(card("d", "", organization: "Такси").hasNoName)
    }
}
