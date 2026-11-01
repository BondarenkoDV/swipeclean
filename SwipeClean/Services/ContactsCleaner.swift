import Contacts
import Foundation

/// Контакт в том виде, в каком он нужен для поиска дублей: только строки, без объектов Contacts.
struct ContactCard: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let organization: String
    let phones: [String]
    let emails: [String]
    var hasImage = false

    /// Ни телефона, ни почты: по такому контакту не позвонить и не написать.
    var isIncomplete: Bool { phones.isEmpty && emails.isEmpty }
    var hasNoName: Bool { name.isEmpty && organization.isEmpty }

    var displayName: String {
        if !name.isEmpty { return name }
        if !organization.isEmpty { return organization }
        return phones.first ?? emails.first ?? String(localized: "Без имени")
    }

    /// Сколько полей заполнено: при объединении основным становится самый полный контакт.
    var richness: Int {
        (name.isEmpty ? 0 : 2) + (organization.isEmpty ? 0 : 1) + phones.count + emails.count + (hasImage ? 1 : 0)
    }
}

/// Поиск дублей и неполных контактов. Чистые функции, проверяются модульными тестами.
enum ContactsAnalysis {
    /// Номер без пробелов, скобок и кода страны: последние 10 цифр. Короче 7 цифр — служебные номера, их не сравниваем.
    static func normalizedPhone(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(10))
    }

    static func normalizedEmail(_ raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return email.contains("@") ? email : nil
    }

    /// Имя без регистра, лишних пробелов и диакритики: «Ёлкин  Пётр» и «елкин петр» совпадают.
    static func normalizedName(_ raw: String) -> String? {
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ru_RU"))
        let words = folded.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Группы дублей: контакты с одинаковым именем, телефоном или почтой. Связи транзитивны:
    /// если A и B совпали по имени, а B и C по телефону, все трое в одной группе.
    /// Внутри группы первым идёт самый полный контакт — он и останется после объединения.
    static func duplicateGroups(_ cards: [ContactCard]) -> [[ContactCard]] {
        var parent = Array(cards.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        var firstByKey: [String: Int] = [:]
        for (index, card) in cards.enumerated() {
            var keys: [String] = []
            if let name = normalizedName(card.name) { keys.append("n:" + name) }
            keys += card.phones.compactMap(normalizedPhone).map { "p:" + $0 }
            keys += card.emails.compactMap(normalizedEmail).map { "e:" + $0 }
            for key in Set(keys) {
                if let first = firstByKey[key] {
                    union(first, index)
                } else {
                    firstByKey[key] = index
                }
            }
        }

        var groups: [Int: [ContactCard]] = [:]
        for index in cards.indices {
            groups[find(index), default: []].append(cards[index])
        }
        return groups.values
            .filter { $0.count > 1 }
            .map { group in group.sorted { $0.richness > $1.richness } }
            .sorted { $0[0].displayName.localizedStandardCompare($1[0].displayName) == .orderedAscending }
    }
}

/// Доступ к контактам и правки в них. Все обращения к CNContactStore идут вне главного потока:
/// на большой адресной книге выборка занимает заметное время.
@MainActor
@Observable
final class ContactsCleaner {
    enum Access {
        case unknown
        case granted
        case denied
    }

    private(set) var access: Access
    private(set) var isLoading = false
    private(set) var cards: [ContactCard] = []
    private(set) var duplicates: [[ContactCard]] = []
    /// Резервные копии: делаются перед каждым объединением и удалением.
    let backups = ContactsBackupStore()

    var incomplete: [ContactCard] {
        cards.filter { $0.isIncomplete && !$0.hasNoName }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Без имени, но с номером или почтой: их стоит подписать или удалить.
    var unnamed: [ContactCard] {
        cards.filter { $0.hasNoName }
    }

    init() {
        access = Self.currentAccess()
    }

    private static func currentAccess() -> Access {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return .granted }
        // С iOS 18 есть ограниченный доступ: работаем с теми контактами, что выбрал пользователь.
        if #available(iOS 18.0, *), status == .limited { return .granted }
        return status == .notDetermined ? .unknown : .denied
    }

    func requestAccessAndLoad() async {
        if access == .unknown {
            let granted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
            access = granted ? .granted : Self.currentAccess()
        }
        guard access == .granted else { return }
        if SwipeCleanApp.isUITesting, ProcessInfo.processInfo.arguments.contains("-seedContacts") {
            await Task.detached { ContactsStoreWork.seedTestContacts() }.value
        }
        await reload()
    }

    func reload() async {
        isLoading = true
        let cards = await Task.detached(priority: .userInitiated) { ContactsStoreWork.fetchCards() }.value
        self.cards = cards
        duplicates = ContactsAnalysis.duplicateGroups(cards)
        isLoading = false
    }

    /// Объединяет каждую группу в её первый (самый полный) контакт. Сначала сохраняет копию всех контактов групп:
    /// если копия не сохранилась, контакты не трогаем. Возвращает копию, чтобы объединение можно было отменить.
    @discardableResult
    func merge(_ groups: [[ContactCard]]) async throws -> ContactsBackup? {
        let plans = groups.map { group in (keep: group[0].id, merge: group.dropFirst().map(\.id)) }
        let targets = plans.flatMap { plan in
            [(id: plan.keep, role: ContactsBackup.Role.kept)] + plan.merge.map { (id: $0, role: ContactsBackup.Role.removed) }
        }
        let backup = try await backUp(.merge, targets: targets)
        try await Task.detached(priority: .userInitiated) {
            for plan in plans {
                try ContactsStoreWork.merge(keep: plan.keep, others: plan.merge)
            }
        }.value
        await reload()
        return backup
    }

    /// Удаляет контакты, сохранив их копию. Возвращает копию, чтобы удаление можно было отменить.
    @discardableResult
    func delete(_ ids: Set<String>) async throws -> ContactsBackup? {
        let ids = Array(ids)
        let backup = try await backUp(.delete, targets: ids.map { (id: $0, role: ContactsBackup.Role.removed) })
        try await Task.detached(priority: .userInitiated) { try ContactsStoreWork.delete(ids) }.value
        await reload()
        return backup
    }

    /// Возвращает контакты из копии и перечитывает книгу. Возвращает, сколько контактов вернулось.
    @discardableResult
    func restore(_ backup: ContactsBackup) async throws -> Int {
        let count = try await backups.restore(backup)
        await reload()
        return count
    }

    /// Копия всей адресной книги по кнопке.
    func backUpAll() async throws {
        guard try await backups.make(.full, targets: nil) != nil else { throw ContactsBackupError.empty }
    }

    private func backUp(_ kind: ContactsBackup.Kind, targets: [(id: String, role: ContactsBackup.Role)]) async throws -> ContactsBackup? {
        do {
            return try await backups.make(kind, targets: targets)
        } catch {
            throw ContactsBackupError.notSaved(error.localizedDescription)
        }
    }
}

/// Работа с CNContactStore. Каждый вызов создаёт своё хранилище: CNContactStore можно использовать с любого потока,
/// но объекты контактов между задачами не передаём, только идентификаторы.
enum ContactsStoreWork {
    /// Поля, которые меняет объединение. Их же возвращает восстановление из копии.
    static var mergeKeys: [CNKeyDescriptor] {
        [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactMiddleNameKey, CNContactOrganizationNameKey,
            CNContactJobTitleKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey,
            CNContactUrlAddressesKey, CNContactBirthdayKey, CNContactImageDataKey, CNContactImageDataAvailableKey,
        ] as [CNKeyDescriptor]
    }

    static func fetchCards() -> [ContactCard] {
        let store = CNContactStore()
        let keys = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var cards: [ContactCard] = []
        try? store.enumerateContacts(with: request) { contact, _ in
            cards.append(ContactCard(
                id: contact.identifier,
                name: CNContactFormatter.string(from: contact, style: .fullName) ?? "",
                organization: contact.organizationName,
                phones: contact.phoneNumbers.map(\.value.stringValue),
                emails: contact.emailAddresses.map { $0.value as String },
                hasImage: contact.imageDataAvailable
            ))
        }
        return cards
    }

    /// Переносит в основной контакт недостающие телефоны, почту, адреса, ссылки, день рождения и фото,
    /// после чего удаляет остальные. Всё одним запросом сохранения. Значения копируются в новые записи:
    /// у записей другого контакта свои идентификаторы.
    static func merge(keep keepID: String, others otherIDs: [String]) throws {
        let store = CNContactStore()
        let predicate = CNContact.predicateForContacts(withIdentifiers: [keepID] + otherIDs)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: mergeKeys)
        guard let main = contacts.first(where: { $0.identifier == keepID })?.mutableCopy() as? CNMutableContact else { return }
        let others = contacts.filter { $0.identifier != keepID }

        var phones = Set(main.phoneNumbers.compactMap { ContactsAnalysis.normalizedPhone($0.value.stringValue) })
        var emails = Set(main.emailAddresses.compactMap { ContactsAnalysis.normalizedEmail($0.value as String) })
        var addresses = Set(main.postalAddresses.map { CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress) })
        var urls = Set(main.urlAddresses.map { ($0.value as String).lowercased() })

        for other in others {
            if main.givenName.isEmpty && main.familyName.isEmpty {
                main.givenName = other.givenName
                main.middleName = other.middleName
                main.familyName = other.familyName
            }
            if main.organizationName.isEmpty { main.organizationName = other.organizationName }
            if main.jobTitle.isEmpty { main.jobTitle = other.jobTitle }
            if main.birthday == nil { main.birthday = other.birthday }
            if main.imageData == nil, other.imageDataAvailable { main.imageData = other.imageData }
            for phone in other.phoneNumbers {
                guard let key = ContactsAnalysis.normalizedPhone(phone.value.stringValue), !phones.contains(key) else { continue }
                phones.insert(key)
                main.phoneNumbers.append(CNLabeledValue(label: phone.label, value: phone.value))
            }
            for email in other.emailAddresses {
                guard let key = ContactsAnalysis.normalizedEmail(email.value as String), !emails.contains(key) else { continue }
                emails.insert(key)
                main.emailAddresses.append(CNLabeledValue(label: email.label, value: email.value))
            }
            for address in other.postalAddresses {
                let key = CNPostalAddressFormatter.string(from: address.value, style: .mailingAddress)
                guard !addresses.contains(key) else { continue }
                addresses.insert(key)
                main.postalAddresses.append(CNLabeledValue(label: address.label, value: address.value))
            }
            for url in other.urlAddresses {
                let key = (url.value as String).lowercased()
                guard !urls.contains(key) else { continue }
                urls.insert(key)
                main.urlAddresses.append(CNLabeledValue(label: url.label, value: url.value))
            }
        }

        let save = CNSaveRequest()
        save.update(main)
        for other in others {
            if let mutable = other.mutableCopy() as? CNMutableContact {
                save.delete(mutable)
            }
        }
        try store.execute(save)
    }

    static func delete(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let store = CNContactStore()
        let contacts = try store.unifiedContacts(
            matching: CNContact.predicateForContacts(withIdentifiers: ids),
            keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
        )
        let save = CNSaveRequest()
        for contact in contacts {
            if let mutable = contact.mutableCopy() as? CNMutableContact {
                save.delete(mutable)
            }
        }
        try store.execute(save)
    }

    /// Только для UI-тестов на симуляторе: пара дублей и контакт без номера. После прошлого прогона
    /// от пары остаётся один объединённый контакт, поэтому добавляется ровно столько, сколько не хватает.
    static func seedTestContacts() {
        let existing = fetchCards()
        let duplicates = existing.filter { $0.name == "Тест Дубль" }.count
        let save = CNSaveRequest()
        var changed = false
        for phone in ["+7 900 111-22-33", "8 (900) 111 22 33"].dropFirst(min(duplicates, 2)) {
            let contact = CNMutableContact()
            contact.givenName = "Тест Дубль"
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))]
            save.add(contact, toContainerWithIdentifier: nil)
            changed = true
        }
        if !existing.contains(where: { $0.name == "Тест Без Номера" }) {
            let incomplete = CNMutableContact()
            incomplete.givenName = "Тест Без Номера"
            save.add(incomplete, toContainerWithIdentifier: nil)
            changed = true
        }
        if changed {
            try? CNContactStore().execute(save)
        }
    }
}
