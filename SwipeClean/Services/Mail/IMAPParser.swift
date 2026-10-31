import Foundation

/// Токен ответа IMAP: атом, строка (в кавычках или литерал) или список в скобках.
enum IMAPToken: Equatable, Sendable {
    case atom(String)
    case string(Data)
    case list([IMAPToken])

    var text: String? {
        switch self {
        case let .atom(value): value
        case let .string(data): String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        case .list: nil
        }
    }
}

/// Что известно о письме из ответа FETCH: номер, размер, дата получения, флаги и выбранные поля заголовка.
struct IMAPFetchRecord: Sendable {
    var uid: UInt32?
    var size: Int64?
    var internalDate: Date?
    var flags: [String] = []
    var header: Data?
}

/// Разбор ответов IMAP и заголовков писем. Чистые функции без сети: их проверяют модульные тесты.
enum IMAPParser {
    /// Поля заголовка, которые запрашиваются у сервера. Тело письма и вложения не запрашиваются никогда:
    /// отправитель, тема и служебные поля рассылок — всё, что нужно, чтобы решить, нужно ли письмо.
    static let headerFields = ["FROM", "SUBJECT", "LIST-UNSUBSCRIBE", "LIST-ID", "PRECEDENCE"]

    // MARK: - Токены

    /// Разбивает одну строку ответа (вместе с литералами) на токены.
    static func tokenize(_ data: Data) -> [IMAPToken] {
        let bytes = [UInt8](data)
        var index = 0
        return parseSequence(bytes, &index, closing: nil)
    }

    private static func parseSequence(_ bytes: [UInt8], _ index: inout Int, closing: UInt8?) -> [IMAPToken] {
        var tokens: [IMAPToken] = []
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: " "), UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\t"):
                index += 1
            case UInt8(ascii: "("):
                index += 1
                tokens.append(.list(parseSequence(bytes, &index, closing: UInt8(ascii: ")"))))
            case UInt8(ascii: ")"):
                index += 1
                if closing == byte { return tokens }
            case UInt8(ascii: "\""):
                index += 1
                tokens.append(.string(parseQuoted(bytes, &index)))
            case UInt8(ascii: "{"):
                if let literal = parseLiteral(bytes, &index) {
                    tokens.append(.string(literal))
                } else {
                    index += 1
                }
            default:
                tokens.append(.atom(parseAtom(bytes, &index)))
            }
        }
        return tokens
    }

    private static func parseQuoted(_ bytes: [UInt8], _ index: inout Int) -> Data {
        var result: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\\"), index < bytes.count {
                result.append(bytes[index])
                index += 1
            } else if byte == UInt8(ascii: "\"") {
                break
            } else {
                result.append(byte)
            }
        }
        return Data(result)
    }

    /// `{N}` CRLF и затем ровно N байт.
    private static func parseLiteral(_ bytes: [UInt8], _ index: inout Int) -> Data? {
        guard let close = bytes[index...].firstIndex(of: UInt8(ascii: "}")) else { return nil }
        let digits = String(decoding: bytes[(index + 1)..<close], as: UTF8.self)
        guard let length = Int(digits), length >= 0 else { return nil }
        var start = close + 1
        if start < bytes.count, bytes[start] == UInt8(ascii: "\r") { start += 1 }
        if start < bytes.count, bytes[start] == UInt8(ascii: "\n") { start += 1 }
        let end = min(start + length, bytes.count)
        index = end
        return Data(bytes[start..<end])
    }

    /// Атом тянется до пробела или скобки; квадратные скобки входят в атом целиком:
    /// `BODY[HEADER.FIELDS (FROM SUBJECT)]` — один атом.
    private static func parseAtom(_ bytes: [UInt8], _ index: inout Int) -> String {
        var result: [UInt8] = []
        var depth = 0
        while index < bytes.count {
            let byte = bytes[index]
            if depth == 0 {
                switch byte {
                case UInt8(ascii: " "), UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "{"), UInt8(ascii: "\""),
                     UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\t"):
                    return String(decoding: result, as: UTF8.self)
                default:
                    break
                }
            }
            if byte == UInt8(ascii: "[") { depth += 1 }
            if byte == UInt8(ascii: "]"), depth > 0 { depth -= 1 }
            result.append(byte)
            index += 1
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// Размер литерала, объявленного в конце строки: `... {123}\r\n`.
    static func literalSize(announcedBy line: [UInt8]) -> Int? {
        var end = line.count
        while end > 0, line[end - 1] == UInt8(ascii: "\r") || line[end - 1] == UInt8(ascii: "\n") { end -= 1 }
        guard end > 0, line[end - 1] == UInt8(ascii: "}"),
              let open = line[..<(end - 1)].lastIndex(of: UInt8(ascii: "{"))
        else { return nil }
        let digits = line[(open + 1)..<(end - 1)]
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    // MARK: - FETCH

    static func fetchRecord(from tokens: [IMAPToken]) -> IMAPFetchRecord? {
        guard tokens.count >= 4, tokens[0] == .atom("*"),
              tokens[2].text?.uppercased() == "FETCH",
              case let .list(items) = tokens[3]
        else { return nil }
        var record = IMAPFetchRecord()
        var index = 0
        while index + 1 < items.count {
            guard case let .atom(key) = items[index] else {
                index += 1
                continue
            }
            let value = items[index + 1]
            switch key.uppercased() {
            case "UID": record.uid = value.text.flatMap { UInt32($0) }
            case "RFC822.SIZE": record.size = value.text.flatMap { Int64($0) }
            case "INTERNALDATE": record.internalDate = value.text.flatMap(internalDate)
            case "FLAGS":
                if case let .list(flags) = value { record.flags = flags.compactMap(\.text) }
            case let name where name.uppercased().hasPrefix("BODY["):
                if case let .string(data) = value { record.header = data }
            default: break
            }
            index += 2
        }
        return record
    }

    // MARK: - Заголовки

    /// Поля заголовка: имя в нижнем регистре → значение без переносов. Повторы берут первое вхождение.
    static func headers(_ data: Data) -> [String: String] {
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        // Сложенные строки (продолжение с пробела или табуляции) склеиваются обратно.
        let unfolded = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n[ \t]+", with: " ", options: .regularExpression)
        var result: [String: String] = [:]
        for line in unfolded.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if result[name] == nil { result[name] = value }
        }
        return result
    }

    private static let encodedWord = try! NSRegularExpression(pattern: "=\\?([^?\\s]+)\\?([BbQq])\\?([^?\\s]*)\\?=")

    /// Раскодирует слова вида `=?UTF-8?B?...?=` (RFC 2047). Соседние закодированные слова склеиваются без пробела.
    static func decodeEncodedWords(_ raw: String) -> String {
        let range = NSRange(raw.startIndex..., in: raw)
        let matches = encodedWord.matches(in: raw, range: range)
        guard !matches.isEmpty else { return raw }
        var result = ""
        var cursor = raw.startIndex
        var previousWasEncoded = false
        for match in matches {
            guard let whole = Range(match.range, in: raw),
                  let charsetRange = Range(match.range(at: 1), in: raw),
                  let kindRange = Range(match.range(at: 2), in: raw),
                  let payloadRange = Range(match.range(at: 3), in: raw)
            else { continue }
            let between = raw[cursor..<whole.lowerBound]
            // Пробелы между двумя закодированными словами — служебные, их не показываем.
            if !(previousWasEncoded && between.allSatisfy(\.isWhitespace)) {
                result += between
            }
            let decoded = decodeWord(charset: String(raw[charsetRange]), kind: raw[kindRange].uppercased(), payload: String(raw[payloadRange]))
            result += decoded ?? String(raw[whole])
            cursor = whole.upperBound
            previousWasEncoded = true
        }
        result += raw[cursor...]
        return result
    }

    private static func decodeWord(charset: String, kind: String, payload: String) -> String? {
        let data: Data?
        if kind == "B" {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else {
            var bytes: [UInt8] = []
            var iterator = Array(payload.utf8).makeIterator()
            while let byte = iterator.next() {
                if byte == UInt8(ascii: "_") {
                    bytes.append(UInt8(ascii: " "))
                } else if byte == UInt8(ascii: "="), let high = iterator.next(), let low = iterator.next(),
                          let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16) {
                    bytes.append(value)
                } else {
                    bytes.append(byte)
                }
            }
            data = Data(bytes)
        }
        guard let data else { return nil }
        return String(data: data, encoding: encoding(named: charset)) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Кодировка по имени из письма: utf-8, koi8-r, windows-1251 и прочие.
    static func encoding(named name: String) -> String.Encoding {
        let base = name.split(separator: "*").first.map(String.init) ?? name
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(base as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    /// Отправитель из поля From: имя и адрес. Подходит для `"Имя" <a@b>`, `Имя <a@b>`, `<a@b>` и просто `a@b`.
    static func sender(from raw: String) -> (name: String, address: String) {
        let decoded = sanitized(decodeEncodedWords(raw))
        guard let open = decoded.lastIndex(of: "<"), let close = decoded[open...].firstIndex(of: ">") else {
            let address = decoded.split(separator: " ").first.map(String.init) ?? decoded
            return (name: "", address: address.lowercased())
        }
        let address = decoded[decoded.index(after: open)..<close].trimmingCharacters(in: .whitespaces).lowercased()
        var name = decoded[..<open].trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        name = name.replacingOccurrences(of: "\\\"", with: "\"")
        return (name: name, address: address)
    }

    /// Строка для показа на экране: без управляющих символов и переносов, с одиночными пробелами.
    static func sanitized(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            return Character(scalar)
        }
        return String(cleaned)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Даты и множества

    // После настройки форматтеры только читаются; DateFormatter потокобезопасен и Sendable, поэтому живёт в статике.
    private static let internalDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatter
    }()

    private static let searchDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy"
        return formatter
    }()

    /// INTERNALDATE: `" 1-Jan-2026 12:00:00 +0000"`.
    static func internalDate(_ raw: String) -> Date? {
        internalDateFormatter.date(from: raw.trimmingCharacters(in: .whitespaces))
    }

    /// Дата в формате критериев SEARCH: `1-Jan-2026`.
    static func searchDate(_ date: Date) -> String {
        searchDateFormatter.string(from: date)
    }

    /// Множество UID для команды: `1:5,7,9:12`.
    static func sequenceSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var parts: [String] = []
        var index = 0
        while index < sorted.count {
            let start = sorted[index]
            var end = start
            while index + 1 < sorted.count, sorted[index + 1] == end + 1 {
                end = sorted[index + 1]
                index += 1
            }
            parts.append(start == end ? "\(start)" : "\(start):\(end)")
            index += 1
        }
        return parts.joined(separator: ",")
    }

    /// Строка в кавычках для команды: кавычки и обратные слэши экранируются.
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Можно ли вставить значение в команду строкой в кавычках: перевод строки или NUL разорвали бы команду
    /// и дали бы серверу (или имени папки с сервера) дописать свою.
    static func isSafeQuoted(_ value: String) -> Bool {
        // По байтам, а не по символам: "\r\n" для Swift один символ, и поиск "\r" его бы не нашёл.
        !value.utf8.contains { $0 == 0x0D || $0 == 0x0A || $0 == 0x00 }
    }

    /// UIDVALIDITY из ответа на SELECT: `* OK [UIDVALIDITY 1234] UIDs valid`. Пока число то же, UID писем
    /// значат то же самое; сменилось — старые UID могут указывать на другие письма.
    static func uidValidity(in untagged: [[IMAPToken]]) -> UInt32? {
        for tokens in untagged where tokens.count >= 3 && tokens[1].text?.uppercased() == "OK" {
            guard let code = tokens[2].text, code.hasPrefix("["), code.hasSuffix("]") else { continue }
            let parts = code.dropFirst().dropLast().split(separator: " ")
            if parts.count == 2, parts[0].uppercased() == "UIDVALIDITY", let value = UInt32(parts[1]) {
                return value
            }
        }
        return nil
    }
}
