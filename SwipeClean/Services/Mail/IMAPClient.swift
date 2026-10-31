import Foundation
import Network

/// Что пошло не так с почтой, в понятных словах.
enum MailError: LocalizedError, Equatable {
    case connectionFailed
    case timeout
    case authenticationFailed
    case serverRefused(String)
    case disconnected
    case trashMissing
    case unsafeErase
    case mailboxChanged
    case invalidName

    /// Обрыв связи, а не отказ сервера: после переподключения ту же порцию можно повторить.
    var isTransient: Bool {
        switch self {
        case .connectionFailed, .timeout, .disconnected: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            String(localized: "Не удалось подключиться к iCloud. Проверьте интернет и попробуйте ещё раз.")
        case .timeout:
            String(localized: "iCloud слишком долго не отвечает. Попробуйте ещё раз.")
        case .authenticationFailed:
            String(localized: "iCloud не принял адрес или пароль. Нужен пароль приложения с account.apple.com, а не пароль Apple ID.")
        case let .serverRefused(text):
            String(localized: "iCloud отклонил запрос: \(text)")
        case .disconnected:
            String(localized: "Соединение с iCloud прервалось.")
        case .trashMissing:
            String(localized: "В ящике нет папки «Удалённые», некуда переносить письма.")
        case .unsafeErase:
            String(localized: "Сервер не умеет стирать письма выборочно (нет UIDPLUS). Ничего не удалено.")
        case .mailboxChanged:
            String(localized: "Папка на сервере изменилась с момента проверки, письма не тронуты. Проверьте почту заново.")
        case .invalidName:
            String(localized: "Адрес, пароль или имя папки содержат недопустимые символы.")
        }
    }
}

/// Сеанс с почтовым ящиком. У настоящего сеанса за этим стоит IMAP, у тестового — набор писем в памяти.
protocol MailSession: Actor {
    func connect(email: String, password: String) async throws
    func disconnect() async
    func mailboxes() async throws -> MailboxSet
    func quota() async throws -> MailQuota?
    /// UID писем папки, пришедших в интервал (или всех, если интервал не задан).
    func search(in mailbox: String, interval: DateInterval?) async throws -> [UInt32]
    func fetchHeaders(_ uids: [UInt32], in mailbox: String) async throws -> [MailMessage]
    /// UIDVALIDITY папки: пока он прежний, найденные при проверке UID указывают на те же письма.
    func uidValidity(of mailbox: String) async throws -> UInt32?
    func moveToTrash(_ uids: [UInt32], from mailbox: String, trash: String) async throws
    /// Стирает письма насовсем.
    func erase(_ uids: [UInt32], in mailbox: String) async throws
}

/// IMAP-клиент для iCloud Mail поверх Network.framework. Только TLS, только imap.mail.me.com.
/// Запрашивает у сервера лишь заголовки (BODY.PEEK[HEADER.FIELDS ...]): тело письма, картинки,
/// ссылки и вложения не загружаются, а письмо не помечается прочитанным.
actor IMAPClient: MailSession {
    static let host = "imap.mail.me.com"
    static let port: UInt16 = 993
    private static let connectTimeout: Double = 20
    private static let commandTimeout: Double = 90
    /// Сколько UID уходит в одну команду: длинные множества серверы режут.
    private static let batchSize = 500

    struct Response: Sendable {
        let untagged: [[IMAPToken]]
        let text: String
    }

    private var connection: NWConnection?
    private var buffer: [UInt8] = []
    private var tagCounter = 0
    private var capabilities: Set<String> = []
    private var selected: String?
    private var validity: [String: UInt32] = [:]

    // MARK: - Подключение

    func connect(email: String, password: String) async throws {
        guard IMAPParser.isSafeQuoted(email), IMAPParser.isSafeQuoted(password) else { throw MailError.invalidName }
        teardown()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { throw MailError.connectionFailed }
        let connection = NWConnection(host: NWEndpoint.Host(Self.host), port: port, using: NWParameters(tls: tls))
        self.connection = connection
        do {
            try await timed(Self.connectTimeout) {
                try await self.waitUntilReady()
                // Приветствие сервера: `* OK ...`.
                _ = try await self.readUnit()
            }
        } catch MailError.timeout {
            throw MailError.timeout
        } catch {
            teardown()
            throw MailError.connectionFailed
        }

        // Apple советует имя без домена, но для многих ящиков работает только полный адрес: пробуем оба.
        var authenticated = false
        for login in Self.logins(for: email) {
            do {
                _ = try await command("LOGIN \(IMAPParser.quoted(login)) \(IMAPParser.quoted(password))")
                authenticated = true
                break
            } catch MailError.authenticationFailed {
                continue
            }
        }
        guard authenticated else {
            teardown()
            throw MailError.authenticationFailed
        }

        let response = try await command("CAPABILITY")
        capabilities = Set(response.untagged.flatMap { tokens -> [String] in
            guard tokens.count > 2, tokens[1].text?.uppercased() == "CAPABILITY" else { return [] }
            return tokens.dropFirst(2).compactMap(\.text).map { $0.uppercased() }
        })
    }

    func disconnect() async {
        if connection != nil {
            tagCounter += 1
            try? await send("A\(tagCounter) LOGOUT")
        }
        teardown()
    }

    static func logins(for email: String) -> [String] {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@") else { return [trimmed] }
        return [trimmed, String(trimmed[..<at])]
    }

    // MARK: - Папки и письма

    func mailboxes() async throws -> MailboxSet {
        let response = try await command("LIST \"\" \"*\"")
        var boxes = MailboxSet()
        var names: [String] = []
        for tokens in response.untagged where tokens.count >= 5 && tokens[1].text?.uppercased() == "LIST" {
            guard case let .list(attributes) = tokens[2], let name = tokens[4].text, IMAPParser.isSafeQuoted(name) else { continue }
            let flags = Set(attributes.compactMap(\.text).map { $0.uppercased() })
            if flags.contains("\\JUNK") { boxes.junk = name }
            if flags.contains("\\TRASH") { boxes.trash = name }
            names.append(name)
        }
        // Без атрибутов SPECIAL-USE папки узнаём по именам, которые используют iCloud и другие серверы.
        boxes.junk = boxes.junk ?? names.first { ["JUNK", "SPAM", "JUNK E-MAIL", "BULK MAIL"].contains($0.uppercased()) }
        boxes.trash = boxes.trash ?? names.first { ["DELETED MESSAGES", "TRASH", "DELETED ITEMS", "BIN"].contains($0.uppercased()) }
        return boxes
    }

    func quota() async throws -> MailQuota? {
        guard capabilities.contains("QUOTA"), let response = try? await command("GETQUOTAROOT INBOX") else { return nil }
        // `* QUOTA "" (STORAGE 1234 5242880)` — в килобайтах.
        for tokens in response.untagged where tokens.count >= 4 && tokens[1].text?.uppercased() == "QUOTA" {
            guard case let .list(items) = tokens[3] else { continue }
            var index = 0
            while index + 2 < items.count {
                if items[index].text?.uppercased() == "STORAGE",
                   let used = items[index + 1].text.flatMap({ Int64($0) }),
                   let limit = items[index + 2].text.flatMap({ Int64($0) }) {
                    return MailQuota(used: used * 1024, limit: limit * 1024)
                }
                index += 3
            }
        }
        return nil
    }

    func search(in mailbox: String, interval: DateInterval?) async throws -> [UInt32] {
        try await select(mailbox)
        var criteria = "ALL"
        if let interval {
            criteria = "SINCE \(IMAPParser.searchDate(interval.start)) BEFORE \(IMAPParser.searchDate(interval.end))"
        }
        let response = try await command("UID SEARCH \(criteria)")
        return response.untagged
            .filter { $0.count >= 2 && $0[1].text?.uppercased() == "SEARCH" }
            .flatMap { $0.dropFirst(2).compactMap { $0.text.flatMap { UInt32($0) } } }
    }

    func fetchHeaders(_ uids: [UInt32], in mailbox: String) async throws -> [MailMessage] {
        guard !uids.isEmpty else { return [] }
        try await select(mailbox)
        var messages: [MailMessage] = []
        for chunk in uids.chunks(of: Self.batchSize) {
            // PEEK: письмо не становится прочитанным. Только перечисленные поля заголовка — никакого тела.
            let fields = IMAPParser.headerFields.joined(separator: " ")
            let response = try await command("UID FETCH \(IMAPParser.sequenceSet(chunk)) (UID RFC822.SIZE INTERNALDATE FLAGS BODY.PEEK[HEADER.FIELDS (\(fields))])")
            for tokens in response.untagged {
                guard let record = IMAPParser.fetchRecord(from: tokens), let message = MailMessage(record: record, mailbox: mailbox) else { continue }
                messages.append(message)
            }
        }
        return messages
    }

    func uidValidity(of mailbox: String) async throws -> UInt32? {
        try await select(mailbox)
        return validity[mailbox]
    }

    func moveToTrash(_ uids: [UInt32], from mailbox: String, trash: String) async throws {
        guard !uids.isEmpty else { return }
        try await select(mailbox)
        for chunk in uids.chunks(of: Self.batchSize) {
            let set = IMAPParser.sequenceSet(chunk)
            if capabilities.contains("MOVE") {
                _ = try await command("UID MOVE \(set) \(IMAPParser.quoted(trash))")
            } else {
                // Без UIDPLUS копию не удалось бы безопасно стереть из исходной папки, поэтому проверяем до COPY.
                guard capabilities.contains("UIDPLUS") else { throw MailError.unsafeErase }
                _ = try await command("UID COPY \(set) \(IMAPParser.quoted(trash))")
                try await expunge(set)
            }
        }
    }

    func erase(_ uids: [UInt32], in mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        try await select(mailbox)
        for chunk in uids.chunks(of: Self.batchSize) {
            try await expunge(IMAPParser.sequenceSet(chunk))
        }
    }

    private func select(_ mailbox: String) async throws {
        guard selected != mailbox else { return }
        let response = try await command("SELECT \(IMAPParser.quoted(mailbox))")
        selected = mailbox
        validity[mailbox] = IMAPParser.uidValidity(in: response.untagged)
    }

    /// Стирает только перечисленные письма. Общий EXPUNGE не используем: он убрал бы и письма, которые другой
    /// почтовый клиент пометил \Deleted, но ещё не стёр. iCloud поддерживает UIDPLUS, так что отказ — защита от
    /// нераспознанного ответа CAPABILITY.
    private func expunge(_ set: String) async throws {
        guard capabilities.contains("UIDPLUS") else { throw MailError.unsafeErase }
        _ = try await command("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
        _ = try await command("UID EXPUNGE \(set)")
    }

    // MARK: - Команды

    /// Отправляет команду и собирает ответ до строки с её тегом. NO и BAD превращаются в ошибки.
    private func command(_ text: String) async throws -> Response {
        tagCounter += 1
        let tag = "A\(tagCounter)"
        let isLogin = text.hasPrefix("LOGIN ")
        // Последний рубеж: команда — ровно одна строка, что бы ни пришло в имени папки или адресе.
        guard IMAPParser.isSafeQuoted(text) else { throw MailError.invalidName }
        return try await timed(Self.commandTimeout) {
            try await self.send("\(tag) \(text)")
            var untagged: [[IMAPToken]] = []
            while true {
                let unit = try await self.readUnit()
                let tokens = IMAPParser.tokenize(Data(unit))
                guard let first = tokens.first?.text else { continue }
                if first == "*" {
                    untagged.append(tokens)
                    continue
                }
                guard first == tag else { continue }
                let status = tokens.count > 1 ? (tokens[1].text ?? "").uppercased() : ""
                let rest = tokens.dropFirst(2).compactMap(\.text).joined(separator: " ")
                switch status {
                case "OK":
                    return Response(untagged: untagged, text: rest)
                case "NO" where isLogin || rest.uppercased().contains("AUTHENTICATIONFAILED"):
                    throw MailError.authenticationFailed
                default:
                    throw MailError.serverRefused(rest)
                }
            }
        }
    }

    /// Ограничивает операцию по времени. При таймауте соединение рвётся, чтобы зависший приём завершился.
    private func timed<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw MailError.timeout
            }
            do {
                guard let result = try await group.next() else { throw MailError.disconnected }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                if case MailError.timeout = error { teardown() }
                throw error
            }
        }
    }

    private func teardown() {
        connection?.cancel()
        connection = nil
        buffer = []
        selected = nil
        capabilities = []
        validity = [:]
    }

    // MARK: - Сеть

    private func waitUntilReady() async throws {
        guard let connection else { throw MailError.disconnected }
        let gate = ResumeOnce<Void>()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.store(continuation)
            connection.stateUpdateHandler = { @Sendable state in
                switch state {
                case .ready: gate.resume(.success(()))
                case let .failed(error): gate.resume(.failure(error))
                case let .waiting(error): gate.resume(.failure(error))
                case .cancelled: gate.resume(.failure(MailError.connectionFailed))
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func send(_ line: String) async throws {
        guard let connection else { throw MailError.disconnected }
        let data = Data((line + "\r\n").utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { @Sendable error in
                if error != nil {
                    // Ошибка сети при отправке — тот же обрыв, что и при приёме: его можно переждать и переподключиться.
                    continuation.resume(throwing: MailError.disconnected)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Дочитывает в буфер следующую порцию данных.
    private func fill() async throws {
        guard let connection else { throw MailError.disconnected }
        let received: (data: Data?, error: NWError?) = await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { @Sendable data, _, _, error in
                continuation.resume(returning: (data: data, error: error))
            }
        }
        if received.error != nil { throw MailError.disconnected }
        guard let data = received.data, !data.isEmpty else { throw MailError.disconnected }
        buffer.append(contentsOf: data)
    }

    private func readLine() async throws -> [UInt8] {
        var searchFrom = 0
        while true {
            if let range = buffer[searchFrom...].firstRange(of: [UInt8(ascii: "\r"), UInt8(ascii: "\n")]) {
                let line = Array(buffer[..<range.upperBound])
                buffer.removeFirst(range.upperBound)
                return line
            }
            searchFrom = max(0, buffer.count - 1)
            try await fill()
        }
    }

    private func readExactly(_ count: Int) async throws -> [UInt8] {
        while buffer.count < count {
            try await fill()
        }
        let bytes = Array(buffer[..<count])
        buffer.removeFirst(count)
        return bytes
    }

    /// Одна строка ответа вместе с литералами, которые она объявляет.
    private func readUnit() async throws -> [UInt8] {
        var unit: [UInt8] = []
        while true {
            let line = try await readLine()
            unit += line
            guard let size = IMAPParser.literalSize(announcedBy: line) else { return unit }
            unit += try await readExactly(size)
        }
    }
}

/// Продолжение, которое можно безопасно возобновить только один раз: обработчик состояния сети зовётся многократно.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    func store(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

extension Array {
    /// Режет массив на куски не длиннее `size`.
    func chunks(of size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
