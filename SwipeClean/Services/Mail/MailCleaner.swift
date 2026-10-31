import Foundation
import SwiftUI

/// Чистка почты iCloud: находит лишние письма по категориям и убирает их одной командой.
/// Пароль приложения лежит в связке ключей, адрес — в настройках. Письма читаются только по заголовкам.
@MainActor
@Observable
final class MailCleaner {
    enum State: Equatable {
        case idle
        case connecting
        case scanning(done: Int, total: Int)
        case finished
        case cleaning(done: Int, total: Int)
    }

    /// Итог чистки: стёртое насовсем освобождает место сразу, перенесённое в «Удалённые» — только после их очистки.
    struct Report: Equatable {
        var count: Int
        var freed: Int64
        var moved: Int64
    }

    private(set) var state: State = .idle
    private(set) var email: String?
    private(set) var found: [MailCategory: [MailMessage]] = [:]
    /// Письма, которые пользователь снял с чистки в списке категории.
    private(set) var excluded: Set<String> = []
    private(set) var selected: Set<MailCategory>
    private(set) var quota: MailQuota?
    private(set) var report: Report?
    var errorMessage: String?

    private let makeSession: @Sendable () -> any MailSession
    private let keychain: KeychainItem
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    /// Номер запуска сканирования: отменённый запуск не трогает состояние нового.
    private var generation = 0
    /// UIDVALIDITY папок на момент проверки: чистка идёт в новом соединении и сверяет его перед удалением.
    private var validity: [String: UInt32] = [:]

    /// Период, за который искали письма в последний раз: по нему видно, подходит ли найденное к новому периоду.
    private var scannedInterval: DateInterval?
    private var hasScanned = false

    /// Сколько писем за раз запрашивается у сервера: достаточно, чтобы полоска прогресса двигалась.
    private static let fetchBatch = 200
    /// Сколько писем удаляется или переносится одной командой. Большие пачки iCloud обрабатывает минутами
    /// и может оборвать соединение, а после обрыва повторять приходится всю пачку. Мелкие пачки к тому же
    /// двигают полоску прогресса и сразу убирают удалённое из списков.
    static let cleanBatch = 100

    init(
        uiTesting: Bool = SwipeCleanApp.isUITesting,
        seeded: Bool = ProcessInfo.processInfo.arguments.contains("-seedMail"),
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        keychain = KeychainItem(
            service: KeychainItem.service("mail", uiTesting: uiTesting),
            account: "icloud"
        )
        #if DEBUG
        if uiTesting {
            makeSession = { FakeMailSession.shared }
        } else {
            makeSession = { IMAPClient() }
        }
        #else
        makeSession = { IMAPClient() }
        #endif
        if uiTesting {
            // UI-тесты начинают без подключённой почты, а с -seedMail — с тестовым ящиком.
            keychain.delete()
            defaults.removeObject(forKey: SettingsKeys.mailAccount)
            if seeded {
                keychain.save(Data("test-pass".utf8))
                defaults.set("test@icloud.com", forKey: SettingsKeys.mailAccount)
            }
        }
        let stored = defaults.string(forKey: SettingsKeys.mailAccount)
        email = keychain.read() != nil ? stored : nil
        if let raw = defaults.string(forKey: SettingsKeys.mailCategories) {
            selected = Set(raw.split(separator: ",").compactMap { MailCategory(rawValue: String($0)) })
        } else {
            selected = MailCategory.defaultSelection
        }
    }

    // MARK: - Состояние

    var isConnected: Bool { email != nil }

    var isBusy: Bool {
        switch state {
        case .connecting, .scanning, .cleaning: true
        case .idle, .finished: false
        }
    }

    /// Подключение или проверка писем.
    var isScanning: Bool {
        switch state {
        case .connecting, .scanning: true
        case .idle, .finished, .cleaning: false
        }
    }

    var isCleaning: Bool {
        if case .cleaning = state { return true }
        return false
    }

    var hasFindings: Bool {
        found.values.contains { !$0.isEmpty }
    }

    /// Писем к чистке без папок «Спам» и «Удалённые»: они переедут в «Удалённые».
    var selectedMovableCount: Int {
        selected.filter { !$0.isPermanent }.reduce(0) { $0 + active(in: $1).count }
    }

    func messages(in category: MailCategory) -> [MailMessage] {
        found[category] ?? []
    }

    /// Письма категории, которые уйдут при чистке.
    func active(in category: MailCategory) -> [MailMessage] {
        messages(in: category).filter { !excluded.contains($0.id) }
    }

    func bytes(in category: MailCategory) -> Int64 {
        active(in: category).reduce(0) { $0 + $1.size }
    }

    var totalBytes: Int64 {
        MailCategory.allCases.reduce(0) { $0 + bytes(in: $1) }
    }

    var selectedCount: Int {
        selected.reduce(0) { $0 + active(in: $1).count }
    }

    var selectedBytes: Int64 {
        selected.reduce(0) { $0 + bytes(in: $1) }
    }

    /// Сколько освободится сразу: только то, что стирается насовсем.
    var selectedPermanentBytes: Int64 {
        selected.filter(\.isPermanent).reduce(0) { $0 + bytes(in: $1) }
    }

    func setSelected(_ category: MailCategory, _ isOn: Bool) {
        if isOn { selected.insert(category) } else { selected.remove(category) }
        defaults.set(selected.map(\.rawValue).sorted().joined(separator: ","), forKey: SettingsKeys.mailCategories)
    }

    func isIncluded(_ message: MailMessage) -> Bool {
        !excluded.contains(message.id)
    }

    func toggle(_ message: MailMessage) {
        if excluded.contains(message.id) { excluded.remove(message.id) } else { excluded.insert(message.id) }
    }

    func setAllIncluded(_ included: Bool, in category: MailCategory) {
        let ids = messages(in: category).map(\.id)
        if included { excluded.subtract(ids) } else { excluded.formUnion(ids) }
    }

    /// Узнаёт у сервера, сколько места занимает почта, не проверяя письма: для экрана памяти iPhone.
    /// Ошибку не показывает: экран памяти тогда просто обходится без этой строки.
    func loadQuota() async {
        guard quota == nil, !isBusy, let email, let password = storedPassword else { return }
        let session = makeSession()
        do {
            try await session.connect(email: email, password: password)
            let quota = try await session.quota()
            if self.quota == nil { self.quota = quota }
        } catch {}
        await session.disconnect()
    }

    // MARK: - Подключение

    func signIn(email: String, password: String) async throws {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .connecting
        let session = makeSession()
        do {
            try await session.connect(email: address, password: secret)
        } catch {
            await session.disconnect()
            state = .idle
            throw error
        }
        await session.disconnect()
        keychain.save(Data(secret.utf8))
        defaults.set(address, forKey: SettingsKeys.mailAccount)
        found = [:]
        excluded = []
        report = nil
        quota = nil
        hasScanned = false
        scannedInterval = nil
        self.email = address
        state = .idle
    }

    /// Удаляет пароль из связки ключей. Сам пароль приложения остаётся действующим, пока его не отозвать у Apple.
    func signOut() {
        reset()
        keychain.delete()
        defaults.removeObject(forKey: SettingsKeys.mailAccount)
        email = nil
        quota = nil
    }

    // MARK: - Сканирование

    func scan(interval: DateInterval?) {
        guard let email, let password = storedPassword else { return }
        task?.cancel()
        generation += 1
        let current = generation
        report = nil
        errorMessage = nil
        scannedInterval = interval
        hasScanned = true
        state = .scanning(done: 0, total: 0)
        task = Task {
            let awake = KeepAwake(name: "mail.scan")
            let link = MailLink(make: makeSession, email: email, password: password)
            do {
                try await performScan(link: link, interval: interval, generation: current)
                if generation == current { state = .finished }
            } catch is CancellationError {
                if generation == current { state = .idle }
            } catch {
                if generation == current {
                    errorMessage = Self.describe(error)
                    state = .idle
                }
            }
            await link.close()
            awake.end()
        }
    }

    /// Проверяет почту, если найденное относится к другому периоду или проверки ещё не было.
    /// Идущую проверку за тот же период не трогает: иначе каждое открытие экрана начинало бы её заново.
    func scanIfNeeded(interval: DateInterval?) {
        guard isConnected, !isCleaning else { return }
        if hasScanned, scannedInterval == interval, isScanning || state == .finished || hasFindings { return }
        reset()
        scan(interval: interval)
    }

    /// Проверяет заново, например по кнопке «Найти лишнее». Идущую проверку за тот же период не обрывает.
    func refresh(interval: DateInterval?) {
        guard isConnected, !isCleaning else { return }
        if hasScanned, scannedInterval == interval, isScanning { return }
        reset()
        scan(interval: interval)
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        if case .scanning = state { state = .idle }
    }

    /// Сбрасывает найденное, например когда сменился период.
    func reset() {
        cancel()
        found = [:]
        excluded = []
        validity = [:]
        report = nil
        hasScanned = false
        scannedInterval = nil
        state = .idle
    }

    private func performScan(link: MailLink, interval: DateInterval?, generation: Int) async throws {
        let boxes = try await link.run { try await $0.mailboxes() }
        let quota = try await link.run { try await $0.quota() }
        if self.generation == generation { self.quota = quota }

        var plan: [(mailbox: String, uids: [UInt32])] = []
        var validity: [String: UInt32] = [:]
        for mailbox in boxes.all {
            try Task.checkCancellation()
            let (uids, value) = try await link.run { session in
                let uids = try await session.search(in: mailbox, interval: interval)
                let value = try await session.uidValidity(of: mailbox)
                return (uids, value)
            }
            // Новые письма идут первыми: так список категории начинается с недавних.
            plan.append((mailbox, uids.sorted(by: >)))
            validity[mailbox] = value
        }
        let total = plan.reduce(0) { $0 + $1.uids.count }
        var done = 0
        if self.generation == generation { state = .scanning(done: 0, total: total) }

        var result: [MailCategory: [MailMessage]] = [:]
        for (mailbox, uids) in plan {
            for chunk in uids.chunks(of: Self.fetchBatch) {
                try Task.checkCancellation()
                let headers = try await link.run { try await $0.fetchHeaders(chunk, in: mailbox) }
                for message in headers {
                    if let category = MailCategorizer.category(for: message, boxes: boxes) {
                        result[category, default: []].append(message)
                    }
                }
                done += chunk.count
                if self.generation == generation { state = .scanning(done: done, total: total) }
            }
        }
        for key in result.keys {
            result[key]?.sort { $0.date > $1.date }
        }
        guard self.generation == generation else { throw CancellationError() }
        found = result
        excluded = []
        self.validity = validity
    }

    // MARK: - Чистка

    /// Убирает выбранные категории: спам и удалённые стираются насовсем, остальное переезжает в «Удалённые».
    /// Письма уходят пачками по `cleanBatch`: после каждой пачки обновляются прогресс и списки, а при обрыве связи
    /// чистка переподключается и продолжает с той же пачки. Повтор безопасен: UID, которых в папке уже нет,
    /// сервер просто пропускает.
    func clean() async {
        guard let email, let password = storedPassword else { return }
        let targets = MailCategory.allCases
            .filter { selected.contains($0) }
            .map { ($0, active(in: $0)) }
            .filter { !$0.1.isEmpty }
        let total = targets.reduce(0) { $0 + $1.1.count }
        guard total > 0 else { return }

        cancel()
        errorMessage = nil
        report = nil
        state = .cleaning(done: 0, total: total)
        let awake = KeepAwake(name: "mail.clean")
        let link = MailLink(make: makeSession, email: email, password: password)
        var done = 0
        var freed: Int64 = 0
        var moved: Int64 = 0
        var stale = false
        do {
            let boxes = try await link.run { try await $0.mailboxes() }
            for (category, messages) in targets {
                let trash = boxes.trash
                if !category.isPermanent, trash == nil { throw MailError.trashMissing }
                for (mailbox, group) in Dictionary(grouping: messages, by: { $0.mailbox }) {
                    let expected = validity[mailbox]
                    for batch in group.chunks(of: Self.cleanBatch) {
                        let uids = batch.map(\.uid)
                        try await link.run { session in
                            // Если сервер пересоздал папку, те же номера UID могут значить другие письма: не трогаем.
                            guard try await session.uidValidity(of: mailbox) == expected else {
                                throw MailError.mailboxChanged
                            }
                            if category.isPermanent {
                                try await session.erase(uids, in: mailbox)
                            } else if let trash {
                                try await session.moveToTrash(uids, from: mailbox, trash: trash)
                            }
                        }
                        let ids = Set(batch.map(\.id))
                        found[category]?.removeAll { ids.contains($0.id) }
                        done += batch.count
                        let batchBytes = batch.reduce(0) { $0 + $1.size }
                        if category.isPermanent { freed += batchBytes } else { moved += batchBytes }
                        state = .cleaning(done: done, total: total)
                    }
                }
            }
        } catch {
            errorMessage = Self.describe(error)
            if (error as? MailError) == .mailboxChanged {
                // Найденное больше не надёжно: пусть пользователь проверит заново.
                found = [:]
                excluded = []
                validity = [:]
                hasScanned = false
                stale = true
            }
        }
        await link.close()
        awake.end()
        if done > 0 {
            report = Report(count: done, freed: freed, moved: moved)
            if let quota {
                self.quota = MailQuota(used: max(0, quota.used - freed), limit: quota.limit)
            }
        }
        state = stale ? .idle : .finished
    }

    private var storedPassword: String? {
        keychain.read().flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func describe(_ error: Error) -> String {
        (error as? MailError)?.errorDescription ?? error.localizedDescription
    }
}

/// Соединение с ящиком, которое переживает обрывы: если связь пропала (iCloud закрыл соединение, телефон сменил сеть
/// или приложение ненадолго ушло в фон), оно переподключается и повторяет шаг. Сдаётся после нескольких неудач подряд.
@MainActor
final class MailLink {
    private let make: @Sendable () -> any MailSession
    private let email: String
    private let password: String
    private var session: any MailSession
    private var isConnected = false
    private var failures = 0

    /// Сколько обрывов подряд переживается. Паузы между попытками растут: 1, 2, 4, 8 и 16 секунд.
    static let maxFailures = 5

    init(make: @escaping @Sendable () -> any MailSession, email: String, password: String) {
        self.make = make
        self.email = email
        self.password = password
        session = make()
    }

    func run<T>(_ step: (any MailSession) async throws -> T) async throws -> T {
        while true {
            try Task.checkCancellation()
            do {
                if !isConnected {
                    try await session.connect(email: email, password: password)
                    isConnected = true
                }
                let value = try await step(session)
                failures = 0
                return value
            } catch let error as MailError where error.isTransient {
                await session.disconnect()
                isConnected = false
                failures += 1
                guard failures <= Self.maxFailures else { throw error }
                try await Task.sleep(for: .seconds(Double(1 << (failures - 1))))
                session = make()
            }
        }
    }

    func close() async {
        await session.disconnect()
        isConnected = false
    }
}
