import Foundation
import SwiftUI

/// Подключённый почтовый ящик.
struct MailAccount: Identifiable, Hashable, Sendable {
    let provider: MailProvider
    let email: String

    var id: MailProvider { provider }
}

/// Чистка почты iCloud и Gmail: находит лишние письма по категориям и убирает их одной командой.
/// Можно подключить оба ящика сразу: категории тогда общие, а письма помнят, из какого они ящика.
/// Пароли приложений лежат в связке ключей, адреса — в настройках. Письма читаются только по заголовкам.
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

    /// Итог чистки: стёртое насовсем освобождает место сразу, перенесённое в корзину — только после её очистки.
    struct Report: Equatable {
        var count: Int
        var freed: Int64
        var moved: Int64
    }

    private(set) var state: State = .idle
    /// Подключённые ящики в порядке MailProvider.allCases: сначала iCloud, потом Gmail.
    private(set) var accounts: [MailAccount] = []
    private(set) var found: [MailCategory: [MailMessage]] = [:]
    /// Все письма из «Входящих» всех ящиков за период, новые первыми: по ним строится список отправителей.
    private(set) var inbox: [MailMessage] = []
    /// Отправители писем из «Входящих», у кого больше писем — первыми. Пересчитывается после проверки и чистки.
    /// Один и тот же адрес в iCloud и Gmail — один отправитель.
    private(set) var senders: [MailSender] = []
    /// Письма, которые пользователь снял с чистки в списке категории.
    private(set) var excluded: Set<String> = []
    private(set) var selected: Set<MailCategory>
    /// Сколько места занято на сервере каждого ящика.
    private(set) var quotas: [MailProvider: MailQuota] = [:]
    private(set) var report: Report?
    var errorMessage: String?

    private let makeSession: @Sendable (MailProvider) -> any MailSession
    private let keychainService: String
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    /// Номер запуска сканирования: отменённый запуск не трогает состояние нового.
    private var generation = 0
    /// UIDVALIDITY папок на момент проверки (ключ — ящик и папка): чистка идёт в новом соединении
    /// и сверяет его перед удалением.
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
        seededGmail: Bool = ProcessInfo.processInfo.arguments.contains("-seedGmail"),
        defaults: UserDefaults = .standard,
        makeSession: (@Sendable (MailProvider) -> any MailSession)? = nil
    ) {
        self.defaults = defaults
        let service = KeychainItem.service("mail", uiTesting: uiTesting)
        keychainService = service
        // Пока не все свойства заданы, методы self вызывать нельзя: связка ключей — через локальную функцию.
        func keychain(for provider: MailProvider) -> KeychainItem {
            KeychainItem(service: service, account: provider.keychainAccount)
        }
        if let makeSession {
            self.makeSession = makeSession
        } else {
            #if DEBUG
            if uiTesting {
                self.makeSession = { FakeMailSession.session(for: $0) }
            } else {
                self.makeSession = { IMAPClient(provider: $0) }
            }
            #else
            self.makeSession = { IMAPClient(provider: $0) }
            #endif
        }
        if uiTesting {
            // UI-тесты начинают без подключённой почты, а с -seedMail и -seedGmail — с тестовыми ящиками.
            for provider in MailProvider.allCases {
                keychain(for: provider).delete()
                defaults.removeObject(forKey: provider.accountKey)
            }
            if seeded {
                keychain(for: .icloud).save(Data("test-pass".utf8))
                defaults.set("test@icloud.com", forKey: MailProvider.icloud.accountKey)
            }
            if seededGmail {
                keychain(for: .gmail).save(Data("testpassgmail".utf8))
                defaults.set("test@gmail.com", forKey: MailProvider.gmail.accountKey)
            }
        }
        accounts = MailProvider.allCases.compactMap { provider -> MailAccount? in
            guard keychain(for: provider).read() != nil, let email = defaults.string(forKey: provider.accountKey) else { return nil }
            return MailAccount(provider: provider, email: email)
        }
        if let raw = defaults.string(forKey: SettingsKeys.mailCategories) {
            selected = Set(raw.split(separator: ",").compactMap { MailCategory(rawValue: String($0)) })
        } else {
            selected = MailCategory.defaultSelection
        }
    }

    // MARK: - Состояние

    var isConnected: Bool { !accounts.isEmpty }

    func account(_ provider: MailProvider) -> MailAccount? {
        accounts.first { $0.provider == provider }
    }

    /// Сервисы, которые ещё можно подключить.
    var availableProviders: [MailProvider] {
        MailProvider.allCases.filter { account($0) == nil }
    }

    /// «iCloud Mail», «Gmail» или «iCloud Mail и Gmail».
    var accountsTitle: String {
        ListFormatter.localizedString(byJoining: accounts.map(\.provider.title))
    }

    func quota(for provider: MailProvider) -> MailQuota? {
        quotas[provider]
    }

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

    /// Писем к чистке без папок «Спам» и «Удалённые»: они переедут в корзину.
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

    // MARK: - Отправители

    func sender(_ address: String) -> MailSender? {
        senders.first { $0.id == address }
    }

    /// Письма отправителя, которые уйдут при чистке: снятые с чистки остаются, где бы их ни сняли.
    func active(from sender: MailSender) -> [MailMessage] {
        sender.messages.filter { !excluded.contains($0.id) }
    }

    func setAllIncluded(_ included: Bool, from sender: MailSender) {
        let ids = sender.messages.map(\.id)
        if included { excluded.subtract(ids) } else { excluded.formUnion(ids) }
    }

    /// Узнаёт у серверов, сколько места занимает почта, не проверяя письма: для экрана памяти iPhone.
    /// Ошибку не показывает: экран памяти тогда просто обходится без этой строки.
    func loadQuota() async {
        guard !isBusy else { return }
        for (account, password) in credentials where quotas[account.provider] == nil {
            let session = makeSession(account.provider)
            do {
                try await session.connect(email: account.email, password: password)
                let quota = try await session.quota()
                if quotas[account.provider] == nil, self.account(account.provider) != nil { quotas[account.provider] = quota }
            } catch {}
            await session.disconnect()
        }
    }

    // MARK: - Подключение

    /// Проверяет адрес и пароль приложения на сервере и, если он их принял, сохраняет ящик.
    /// Найденное раньше сбрасывается: с новым ящиком почту нужно проверить заново.
    func signIn(provider: MailProvider = .icloud, email: String, password: String) async throws {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = provider.normalizedPassword(password)
        let wasConnected = isConnected
        if !wasConnected { state = .connecting }
        let session = makeSession(provider)
        do {
            try await session.connect(email: address, password: secret)
        } catch {
            await session.disconnect()
            if !wasConnected { state = .idle }
            throw error
        }
        await session.disconnect()
        keychain(for: provider).save(Data(secret.utf8))
        defaults.set(address, forKey: provider.accountKey)
        reset()
        quotas[provider] = nil
        accounts.removeAll { $0.provider == provider }
        accounts.append(MailAccount(provider: provider, email: address))
        accounts.sort { Self.order($0.provider) < Self.order($1.provider) }
    }

    /// Отключает ящик: удаляет пароль из связки ключей. Сам пароль приложения остаётся действующим,
    /// пока его не отозвать у Apple или Google. Найденное сбрасывается, чтобы письма отключённого ящика
    /// не остались в списках.
    func signOut(_ provider: MailProvider) {
        reset()
        keychain(for: provider).delete()
        defaults.removeObject(forKey: provider.accountKey)
        accounts.removeAll { $0.provider == provider }
        quotas[provider] = nil
    }

    /// Отключает все ящики.
    func signOut() {
        for provider in MailProvider.allCases {
            signOut(provider)
        }
    }

    // MARK: - Сканирование

    func scan(interval: DateInterval?) {
        let targets = credentials
        guard !targets.isEmpty else { return }
        task?.cancel()
        generation += 1
        let current = generation
        report = nil
        errorMessage = nil
        scannedInterval = interval
        hasScanned = true
        state = .scanning(done: 0, total: 0)
        let make = makeSession
        task = Task {
            let awake = KeepAwake(name: "mail.scan")
            let links = targets.map { account, password in
                let provider = account.provider
                return (account: account, link: MailLink(make: { make(provider) }, email: account.email, password: password))
            }
            do {
                let failures = try await performScan(links: links, interval: interval, generation: current)
                if generation == current {
                    if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
                    // Не ответил ни один ящик: показывать нечего, как и раньше с одним ящиком.
                    state = failures.count == links.count ? .idle : .finished
                }
            } catch is CancellationError {
                if generation == current { state = .idle }
            } catch {
                if generation == current {
                    errorMessage = Self.describe(error, for: nil)
                    state = .idle
                }
            }
            for item in links {
                await item.link.close()
            }
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
        setInbox([])
        excluded = []
        validity = [:]
        report = nil
        hasScanned = false
        scannedInterval = nil
        state = .idle
    }

    /// Проверяет все подключённые ящики по очереди. Ящик, который не ответил, не мешает остальным:
    /// его ошибка возвращается в списке, а найденное в других ящиках показывается.
    private func performScan(links: [(account: MailAccount, link: MailLink)], interval: DateInterval?, generation: Int) async throws -> [String] {
        struct Plan {
            let account: MailAccount
            let link: MailLink
            let boxes: MailboxSet
            let folders: [(mailbox: String, uids: [UInt32])]
        }
        var plans: [Plan] = []
        var failures: [String] = []
        var validity: [String: UInt32] = [:]
        for (account, link) in links {
            do {
                let boxes = try await link.run { try await $0.mailboxes() }
                let quota = try await link.run { try await $0.quota() }
                if self.generation == generation { quotas[account.provider] = quota }
                var folders: [(mailbox: String, uids: [UInt32])] = []
                for mailbox in boxes.all {
                    try Task.checkCancellation()
                    let (uids, value) = try await link.run { session in
                        let uids = try await session.search(in: mailbox, interval: interval)
                        let value = try await session.uidValidity(of: mailbox)
                        return (uids, value)
                    }
                    // Новые письма идут первыми: так список категории начинается с недавних.
                    folders.append((mailbox, uids.sorted(by: >)))
                    validity[Self.key(account.provider, mailbox)] = value
                }
                plans.append(Plan(account: account, link: link, boxes: boxes, folders: folders))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(Self.describe(error, for: links.count > 1 ? account.provider : nil, provider: account.provider))
            }
        }
        let total = plans.reduce(0) { $0 + $1.folders.reduce(0) { $0 + $1.uids.count } }
        var done = 0
        if self.generation == generation { state = .scanning(done: 0, total: total) }

        var result: [MailCategory: [MailMessage]] = [:]
        var inbox: [MailMessage] = []
        for plan in plans {
            // Найденное в ящике попадает в общий итог, только если ящик проверен целиком.
            var mine: [MailCategory: [MailMessage]] = [:]
            var mineInbox: [MailMessage] = []
            do {
                for (mailbox, uids) in plan.folders {
                    for chunk in uids.chunks(of: Self.fetchBatch) {
                        try Task.checkCancellation()
                        let headers = try await plan.link.run { try await $0.fetchHeaders(chunk, in: mailbox) }
                        for header in headers {
                            let message = header.tagged(plan.account.provider)
                            if let category = MailCategorizer.category(for: message, boxes: plan.boxes) {
                                mine[category, default: []].append(message)
                            }
                            if mailbox == plan.boxes.inbox { mineInbox.append(message) }
                        }
                        done += chunk.count
                        if self.generation == generation { state = .scanning(done: done, total: total) }
                    }
                }
                for (category, messages) in mine {
                    result[category, default: []] += messages
                }
                inbox += mineInbox
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(Self.describe(error, for: links.count > 1 ? plan.account.provider : nil, provider: plan.account.provider))
            }
        }
        for key in result.keys {
            result[key]?.sort { $0.date > $1.date }
        }
        guard self.generation == generation else { throw CancellationError() }
        found = result
        setInbox(inbox.sorted { $0.date > $1.date })
        excluded = []
        self.validity = validity
        return failures
    }

    // MARK: - Чистка

    /// Убирает выбранные категории: спам и удалённые стираются насовсем, остальное переезжает в корзину ящика.
    func clean() async {
        let targets = MailCategory.allCases
            .filter { selected.contains($0) }
            .map { (permanent: $0.isPermanent, messages: active(in: $0)) }
        await remove(targets)
    }

    /// Переносит в корзину всё от выбранных отправителей, кроме писем, снятых с чистки.
    /// Вернуть письма можно в Почте или Gmail, пока корзина не очищена.
    func cleanSenders(_ addresses: Set<String>) async {
        let messages = senders
            .filter { addresses.contains($0.id) }
            .flatMap { active(from: $0) }
        await remove([(permanent: false, messages: messages)])
    }

    /// Ящики чистятся по очереди, каждый в своём соединении. Письма уходят пачками по `cleanBatch`: после каждой
    /// пачки обновляются прогресс и списки, а при обрыве связи чистка переподключается и продолжает с той же
    /// пачки. Повтор безопасен: UID, которых в папке уже нет, сервер просто пропускает. Ошибка в одном ящике
    /// не мешает почистить другой.
    private func remove(_ targets: [(permanent: Bool, messages: [MailMessage])]) async {
        let credentials = self.credentials
        let targets = targets.filter { !$0.messages.isEmpty }
        let total = targets.reduce(0) { $0 + $1.messages.count }
        guard !credentials.isEmpty, total > 0 else { return }

        cancel()
        errorMessage = nil
        report = nil
        state = .cleaning(done: 0, total: total)
        let awake = KeepAwake(name: "mail.clean")
        var done = 0
        var freed: Int64 = 0
        var moved: Int64 = 0
        var freedBy: [MailProvider: Int64] = [:]
        var failures: [String] = []
        var stale = false
        let make = makeSession
        for (account, password) in credentials {
            let provider = account.provider
            let mine = targets
                .map { target in (permanent: target.permanent, messages: target.messages.filter { $0.account == provider }) }
                .filter { !$0.messages.isEmpty }
            guard !mine.isEmpty else { continue }
            let link = MailLink(make: { make(provider) }, email: account.email, password: password)
            do {
                let boxes = try await link.run { try await $0.mailboxes() }
                for (permanent, messages) in mine {
                    let trash = boxes.trash
                    if !permanent, trash == nil { throw MailError.trashMissing }
                    for (mailbox, group) in Dictionary(grouping: messages, by: { $0.mailbox }) {
                        let expected = validity[Self.key(provider, mailbox)]
                        for batch in group.chunks(of: Self.cleanBatch) {
                            let uids = batch.map(\.uid)
                            try await link.run { session in
                                // Если сервер пересоздал папку, те же номера UID могут значить другие письма: не трогаем.
                                guard try await session.uidValidity(of: mailbox) == expected else {
                                    throw MailError.mailboxChanged
                                }
                                if permanent {
                                    try await session.erase(uids, in: mailbox)
                                } else if let trash {
                                    try await session.moveToTrash(uids, from: mailbox, trash: trash)
                                }
                            }
                            forget(Set(batch.map(\.id)))
                            done += batch.count
                            let batchBytes = batch.reduce(0) { $0 + $1.size }
                            if permanent {
                                freed += batchBytes
                                freedBy[provider, default: 0] += batchBytes
                            } else {
                                moved += batchBytes
                            }
                            state = .cleaning(done: done, total: total)
                        }
                    }
                }
            } catch {
                failures.append(Self.describe(error, for: credentials.count > 1 ? provider : nil, provider: provider))
                if (error as? MailError) == .mailboxChanged { stale = true }
            }
            await link.close()
        }
        awake.end()
        if stale {
            // Найденное больше не надёжно: пусть пользователь проверит заново.
            found = [:]
            setInbox([])
            excluded = []
            validity = [:]
            hasScanned = false
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        if done > 0 {
            report = Report(count: done, freed: freed, moved: moved)
            for (provider, bytes) in freedBy {
                if let quota = quotas[provider] {
                    quotas[provider] = MailQuota(used: max(0, quota.used - bytes), limit: quota.limit)
                }
            }
        }
        state = stale ? .idle : .finished
    }

    /// Убирает ушедшие письма из категорий и из списка отправителей.
    private func forget(_ ids: Set<String>) {
        for key in found.keys {
            found[key]?.removeAll { ids.contains($0.id) }
        }
        let remaining = inbox.filter { !ids.contains($0.id) }
        if remaining.count != inbox.count { setInbox(remaining) }
    }

    private func setInbox(_ messages: [MailMessage]) {
        inbox = messages
        senders = MailSenderGrouper.group(messages)
    }

    // MARK: - Пароли

    /// Подключённые ящики вместе с паролями из связки ключей. Ящик без пароля пропускается.
    private var credentials: [(account: MailAccount, password: String)] {
        accounts.compactMap { account -> (account: MailAccount, password: String)? in
            guard let password = keychain(for: account.provider).read().flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
            return (account, password)
        }
    }

    private func keychain(for provider: MailProvider) -> KeychainItem {
        KeychainItem(service: keychainService, account: provider.keychainAccount)
    }

    private static func key(_ provider: MailProvider, _ mailbox: String) -> String {
        "\(provider.rawValue):\(mailbox)"
    }

    private static func order(_ provider: MailProvider) -> Int {
        MailProvider.allCases.firstIndex(of: provider) ?? 0
    }

    /// Текст ошибки. Когда подключено несколько ящиков, впереди стоит имя ящика: «Gmail: …».
    private static func describe(_ error: Error, for label: MailProvider?, provider: MailProvider = .icloud) -> String {
        let text = (error as? MailError)?.message(for: provider) ?? error.localizedDescription
        guard let label else { return text }
        return "\(label.title): \(text)"
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
