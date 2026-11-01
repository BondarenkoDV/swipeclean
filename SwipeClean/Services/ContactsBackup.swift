import Contacts
import Foundation

/// Резервная копия контактов: файл vCard и описание, какие контакты в нём и что с ними собирались сделать.
/// У контактов нет «Недавно удалённых», поэтому копия делается перед каждым объединением и удалением.
struct ContactsBackup: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Перед объединением дублей.
        case merge
        /// Перед удалением выбранных контактов.
        case delete
        /// Вся адресная книга по кнопке.
        case full
    }

    enum Role: String, Codable, Sendable {
        /// Остался после объединения: при восстановлении ему возвращается прежний вид.
        case kept
        /// Удалён: при восстановлении добавляется заново.
        case removed
        /// Из полной копии: возвращается, только если такого контакта больше нет.
        case snapshot
    }

    struct Entry: Codable, Hashable, Sendable {
        /// Идентификатор контакта в момент копии.
        let id: String
        let name: String
        let role: Role
        /// Было ли фото. Если не было, а объединение его добавило, при восстановлении фото снимается.
        let hasImage: Bool
        /// Аккаунт (iCloud, Gmail…), куда вернуть удалённый контакт.
        let container: String?
    }

    let id: UUID
    let date: Date
    let kind: Kind
    /// Контакты в том же порядке, что и в файле.
    let entries: [Entry]
    /// Имя файла .vcf: его же видно, когда копию сохраняют в «Файлы» или отправляют.
    let fileName: String
    var restoredAt: Date?

    init(id: UUID = UUID(), date: Date = .now, kind: Kind, entries: [Entry], restoredAt: Date? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.entries = entries
        self.restoredAt = restoredAt
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let stamp = String(
            format: "%04ld-%02ld-%02ld %02ld-%02ld-%02ld",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        fileName = "Contacts \(stamp) \(id.uuidString.prefix(4)).vcf"
    }
}

/// Что сделать с каждым контактом копии при восстановлении. Чистая функция, проверяется модульными тестами.
enum ContactsRestorePlan {
    enum Action: Equatable, Sendable {
        /// Добавить контакт заново.
        case add
        /// Вернуть существующему контакту поля из копии.
        case update(String)
        /// Контакт на месте и менять его не нужно.
        case skip
    }

    static func actions(for entries: [ContactsBackup.Entry], existing: Set<String>) -> [Action] {
        entries.map { entry in
            let exists = existing.contains(entry.id)
            switch entry.role {
            case .kept: return exists ? .update(entry.id) : .add
            case .removed, .snapshot: return exists ? .skip : .add
            }
        }
    }
}

/// Сколько копий хранить: перед объединением и удалением — последние 30, полных — последние 5 (они крупнее).
enum ContactsBackupRetention {
    static let operationLimit = 30
    static let fullLimit = 5

    /// Делит копии на те, что остаются (новые первыми), и те, что пора удалить вместе с файлами.
    static func split(_ backups: [ContactsBackup]) -> (keep: [ContactsBackup], drop: [ContactsBackup]) {
        var keep: [ContactsBackup] = []
        var drop: [ContactsBackup] = []
        var operations = 0
        var full = 0
        for backup in backups.sorted(by: { $0.date > $1.date }) {
            if backup.kind == .full {
                full += 1
                if full <= fullLimit { keep.append(backup) } else { drop.append(backup) }
            } else {
                operations += 1
                if operations <= operationLimit { keep.append(backup) } else { drop.append(backup) }
            }
        }
        return (keep, drop)
    }
}

enum ContactsBackupError: LocalizedError {
    case unreadable
    case mismatch
    case empty
    case notSaved(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            String(localized: "Файл копии не читается.")
        case .mismatch:
            String(localized: "Копия не совпадает со своим описанием. Откройте файл .vcf в «Контактах», чтобы вернуть контакты вручную.")
        case .empty:
            String(localized: "В адресной книге нет контактов, копировать нечего.")
        case .notSaved(let reason):
            String(localized: "Не удалось сохранить резервную копию, поэтому контакты не тронуты. \(reason)")
        }
    }
}

/// Запись и чтение vCard. Contacts не кладёт в vCard фото, поэтому оно добавляется отдельной строкой PHOTO.
/// Заметки iOS отдаёт только приложениям с особым разрешением Apple, поэтому в копию они не попадают.
enum ContactsVCard {
    /// Один vCard на контакт, по порядку. `photos[i]` — фото i-го контакта или nil.
    static func data(for contacts: [CNContact], photos: [Data?]) throws -> Data {
        var text = ""
        for (index, contact) in contacts.enumerated() {
            let data = try CNContactVCardSerialization.data(with: [contact])
            guard var card = String(data: data, encoding: .utf8) else { throw ContactsBackupError.unreadable }
            if index < photos.count, let photo = photos[index], !photo.isEmpty, self.photo(in: card) == nil {
                card = insertingPhoto(photo, into: card)
            }
            if card.utf8.last != UInt8(ascii: "\n") { card += "\r\n" }
            text += card
        }
        return Data(text.utf8)
    }

    /// Добавляет строку PHOTO перед END:VCARD. Длинная строка переносится по стандарту vCard: перевод строки и пробел.
    static func insertingPhoto(_ photo: Data, into card: String) -> String {
        guard let end = card.range(of: "END:VCARD", options: [.backwards, .caseInsensitive]) else { return card }
        let newline = card.utf8.contains(13) ? "\r\n" : "\n"
        let type = photo.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "PNG" : "JPEG"
        let line = "PHOTO;ENCODING=b;TYPE=\(type):" + photo.base64EncodedString()
        return card.replacingCharacters(in: end, with: folded(line, newline: newline) + newline + "END:VCARD")
    }

    /// Первая строка до 75 символов, продолжения по 74 с пробелом в начале. Строка здесь только из ASCII.
    static func folded(_ line: String, newline: String) -> String {
        var parts = [line.prefix(75)]
        var rest = line.dropFirst(75)
        while !rest.isEmpty {
            parts.append(rest.prefix(74))
            rest = rest.dropFirst(74)
        }
        return parts.joined(separator: newline + " ")
    }

    /// Карточки BEGIN:VCARD … END:VCARD из файла, каждая отдельной строкой с переводами CRLF.
    static func cards(in text: String) -> [String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var cards: [String] = []
        var current: [Substring] = []
        var inside = false
        for line in lines {
            let marker = line.trimmingCharacters(in: .whitespaces).uppercased()
            if marker == "BEGIN:VCARD" {
                current = [line]
                inside = true
            } else if inside {
                current.append(line)
                if marker == "END:VCARD" {
                    cards.append(current.joined(separator: "\r\n") + "\r\n")
                    inside = false
                }
            }
        }
        return cards
    }

    /// Фото из строки PHOTO в base64 (vCard 3.0 ENCODING=b или data: URI из vCard 4.0). Ссылки на сеть не открываем.
    static func photo(in card: String) -> Data? {
        let unfolded = card.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")
        for line in unfolded.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let head = line[..<colon].uppercased()
            guard head == "PHOTO" || head.hasPrefix("PHOTO;") else { continue }
            var value = line[line.index(after: colon)...]
            if value.lowercased().hasPrefix("data:") {
                guard let comma = value.firstIndex(of: ","), value[..<comma].lowercased().hasSuffix(";base64") else { continue }
                value = value[value.index(after: comma)...]
            } else if !(head.contains("ENCODING=B") || head.contains("BASE64")) {
                continue
            }
            if let data = Data(base64Encoded: String(value), options: .ignoreUnknownCharacters), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    /// Контакты из файла копии по порядку, с фото.
    static func contacts(from data: Data) throws -> [CNContact] {
        guard let text = String(data: data, encoding: .utf8) else { throw ContactsBackupError.unreadable }
        return try cards(in: text).map { card -> CNContact in
            guard let contact = try CNContactVCardSerialization.contacts(with: Data(card.utf8)).first else {
                throw ContactsBackupError.unreadable
            }
            if contact.isKeyAvailable(CNContactImageDataKey), contact.imageData != nil { return contact }
            guard let photo = photo(in: card), let mutable = contact.mutableCopy() as? CNMutableContact else { return contact }
            mutable.imageData = photo
            return mutable
        }
    }

    /// Возвращает оставшемуся после объединения контакту поля из копии: ровно те, что меняет объединение.
    /// Сам контакт не пересоздаётся, поэтому его заметка и связи с другими аккаунтами остаются.
    static func restoreFields(of target: CNMutableContact, from source: CNContact, hadImage: Bool) {
        if source.isKeyAvailable(CNContactGivenNameKey) { target.givenName = source.givenName }
        if source.isKeyAvailable(CNContactMiddleNameKey) { target.middleName = source.middleName }
        if source.isKeyAvailable(CNContactFamilyNameKey) { target.familyName = source.familyName }
        if source.isKeyAvailable(CNContactOrganizationNameKey) { target.organizationName = source.organizationName }
        if source.isKeyAvailable(CNContactJobTitleKey) { target.jobTitle = source.jobTitle }
        if source.isKeyAvailable(CNContactBirthdayKey) { target.birthday = source.birthday }
        if source.isKeyAvailable(CNContactPhoneNumbersKey) {
            target.phoneNumbers = source.phoneNumbers.map { CNLabeledValue(label: $0.label, value: $0.value) }
        }
        if source.isKeyAvailable(CNContactEmailAddressesKey) {
            target.emailAddresses = source.emailAddresses.map { CNLabeledValue(label: $0.label, value: $0.value) }
        }
        if source.isKeyAvailable(CNContactPostalAddressesKey) {
            target.postalAddresses = source.postalAddresses.map { CNLabeledValue(label: $0.label, value: $0.value) }
        }
        if source.isKeyAvailable(CNContactUrlAddressesKey) {
            target.urlAddresses = source.urlAddresses.map { CNLabeledValue(label: $0.label, value: $0.value) }
        }
        // Объединение добавляет фото только контакту без фото, поэтому вернуть прежний вид — значит снять его.
        if !hadImage { target.imageData = nil }
    }
}

/// Работа с CNContactStore и файлами копий вне главного потока: на большой книге это заметное время.
enum ContactsBackupWork {
    /// Сохраняет копию контактов из списка (или всей книги, если списка нет) и возвращает её описание.
    /// Nil — ни одного контакта из списка уже нет, сохранять нечего.
    static func make(kind: ContactsBackup.Kind, targets: [(id: String, role: ContactsBackup.Role)]?, directory: URL) throws -> ContactsBackup? {
        let store = CNContactStore()
        let isFull = targets == nil
        let keys: [CNKeyDescriptor] = [
            CNContactVCardSerialization.descriptorForRequiredKeys(),
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
            // В полную копию идут миниатюры: фото всей книги в полном размере заняли бы десятки мегабайт.
            (isFull ? CNContactThumbnailImageDataKey : CNContactImageDataKey) as CNKeyDescriptor,
        ]

        var contacts: [CNContact] = []
        var roles: [ContactsBackup.Role] = []
        if let targets {
            let found = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(withIdentifiers: targets.map(\.id)),
                keysToFetch: keys
            )
            let byID = Dictionary(found.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            for target in targets {
                guard let contact = byID[target.id] else { continue }
                contacts.append(contact)
                roles.append(target.role)
            }
        } else {
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.sortOrder = .userDefault
            try store.enumerateContacts(with: request) { contact, _ in
                contacts.append(contact)
            }
            roles = Array(repeating: .snapshot, count: contacts.count)
        }
        guard !contacts.isEmpty else { return nil }

        let photos: [Data?] = contacts.map { contact in
            guard contact.imageDataAvailable else { return nil }
            return isFull ? contact.thumbnailImageData : contact.imageData
        }
        let data = try ContactsVCard.data(for: contacts, photos: photos)
        let entries = zip(contacts, roles).map { contact, role in
            ContactsBackup.Entry(
                id: contact.identifier,
                name: displayName(contact),
                role: role,
                hasImage: contact.imageDataAvailable,
                container: isFull ? nil : container(of: contact.identifier, in: store)
            )
        }
        let backup = ContactsBackup(kind: kind, entries: entries)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(backup.fileName), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return backup
    }

    /// Возвращает контакты из копии одним запросом сохранения. Возвращает, сколько контактов добавлено или исправлено.
    static func restore(_ backup: ContactsBackup, directory: URL) throws -> Int {
        let data = try Data(contentsOf: directory.appendingPathComponent(backup.fileName))
        let contacts = try ContactsVCard.contacts(from: data)
        guard contacts.count == backup.entries.count else { throw ContactsBackupError.mismatch }

        let store = CNContactStore()
        var existing = Set<String>()
        try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])) { contact, _ in
            existing.insert(contact.identifier)
        }
        let actions = ContactsRestorePlan.actions(for: backup.entries, existing: existing)
        let updateIDs = actions.compactMap { action -> String? in
            if case .update(let id) = action { return id }
            return nil
        }
        let current = try updateIDs.isEmpty ? [] : store.unifiedContacts(
            matching: CNContact.predicateForContacts(withIdentifiers: updateIDs),
            keysToFetch: ContactsStoreWork.mergeKeys
        )
        // Аккаунт мог пропасть (например, отключили Gmail): тогда контакт вернётся в аккаунт по умолчанию.
        let containers = Set(((try? store.containers(matching: nil)) ?? []).map(\.identifier))

        let save = CNSaveRequest()
        var restored = 0
        for (index, action) in actions.enumerated() {
            let entry = backup.entries[index]
            switch action {
            case .skip:
                continue
            case .add:
                guard let copy = contacts[index].mutableCopy() as? CNMutableContact else { continue }
                let container = entry.container.flatMap { containers.contains($0) ? $0 : nil }
                save.add(copy, toContainerWithIdentifier: container)
            case .update(let id):
                guard let target = current.first(where: { $0.identifier == id })?.mutableCopy() as? CNMutableContact else { continue }
                ContactsVCard.restoreFields(of: target, from: contacts[index], hadImage: entry.hasImage)
                save.update(target)
            }
            restored += 1
        }
        if restored > 0 {
            try store.execute(save)
        }
        return restored
    }

    private static func container(of id: String, in store: CNContactStore) -> String? {
        let predicate = CNContainer.predicateForContainerOfContact(withIdentifier: id)
        return (try? store.containers(matching: predicate))?.first?.identifier
    }

    private static func displayName(_ contact: CNContact) -> String {
        if let name = CNContactFormatter.string(from: contact, style: .fullName), !name.isEmpty { return name }
        if !contact.organizationName.isEmpty { return contact.organizationName }
        if let phone = contact.phoneNumbers.first?.value.stringValue { return phone }
        if let email = contact.emailAddresses.first?.value { return email as String }
        return String(localized: "Без имени")
    }
}

/// Список копий и файлы на диске. Описание копий лежит в index.json рядом с файлами .vcf.
@MainActor
@Observable
final class ContactsBackupStore {
    /// Новые первыми.
    private(set) var items: [ContactsBackup] = []
    let directory: URL

    /// Папку UI-тестов чистим один раз за запуск приложения, а не при каждом открытии экрана.
    private static var testDirectoryPrepared = false

    init(directory: URL? = nil) {
        let directory = directory ?? Self.defaultDirectory()
        self.directory = directory
        items = Self.loadIndex(in: directory)
    }

    /// Application Support/ContactBackups: попадает в резервную копию iPhone, но не видна в «Файлах».
    static func defaultDirectory() -> URL {
        let fileManager = FileManager.default
        if SwipeCleanApp.isUITesting {
            let url = fileManager.temporaryDirectory.appendingPathComponent("contact-backups-uitest", isDirectory: true)
            if !testDirectoryPrepared {
                try? fileManager.removeItem(at: url)
                testDirectoryPrepared = true
            }
            return url
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContactBackups", isDirectory: true)
    }

    func fileURL(for backup: ContactsBackup) -> URL {
        directory.appendingPathComponent(backup.fileName)
    }

    /// Копия контактов из списка; без списка — всей книги.
    func make(_ kind: ContactsBackup.Kind, targets: [(id: String, role: ContactsBackup.Role)]?) async throws -> ContactsBackup? {
        let directory = directory
        let backup = try await Task.detached(priority: .userInitiated) {
            try ContactsBackupWork.make(kind: kind, targets: targets, directory: directory)
        }.value
        if let backup { add(backup) }
        return backup
    }

    func restore(_ backup: ContactsBackup) async throws -> Int {
        let directory = directory
        let count = try await Task.detached(priority: .userInitiated) {
            try ContactsBackupWork.restore(backup, directory: directory)
        }.value
        if let index = items.firstIndex(where: { $0.id == backup.id }) {
            items[index].restoredAt = .now
            saveIndex()
        }
        return count
    }

    func delete(_ backup: ContactsBackup) {
        try? FileManager.default.removeItem(at: fileURL(for: backup))
        items.removeAll { $0.id == backup.id }
        saveIndex()
    }

    /// Новая копия встаёт первой; самые старые сверх лимита удаляются вместе с файлами.
    func add(_ backup: ContactsBackup) {
        let split = ContactsBackupRetention.split([backup] + items.filter { $0.id != backup.id })
        for old in split.drop {
            try? FileManager.default.removeItem(at: fileURL(for: old))
        }
        items = split.keep
        saveIndex()
    }

    private var indexURL: URL {
        directory.appendingPathComponent("index.json")
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Копии без файла (например, после сбоя записи) не показываем: вернуть из них нечего.
    private static func loadIndex(in directory: URL) -> [ContactsBackup] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
              let list = try? JSONDecoder().decode([ContactsBackup].self, from: data) else { return [] }
        return list
            .filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.fileName).path) }
            .sorted { $0.date > $1.date }
    }
}
