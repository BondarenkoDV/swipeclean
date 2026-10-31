import SwiftUI

/// Чистка почты iCloud: спам, удалённые, рассылки, тяжёлые и старые непрочитанные письма за выбранный период —
/// одной кнопкой. Приложение читает только заголовки: письма не открываются, ссылки не переходятся,
/// вложения не скачиваются, поэтому фишинговое письмо не может навредить.
struct MailCleanView: View {
    /// Общий на всё приложение (задаётся в MainTabView): проверка не обрывается при уходе с экрана,
    /// а найденное не ищется заново при каждом открытии.
    @Environment(MailCleaner.self) private var cleaner
    @AppStorage(SettingsKeys.mailPeriod) private var period = SmartCleanPeriod.all
    @State private var isConnecting = false
    @State private var isPickingPeriod = false
    @State private var confirmClean = false
    @State private var confirmSignOut = false

    private var interval: DateInterval? {
        period.interval()
    }

    private var isCleaning: Bool {
        if case .cleaning = cleaner.state { return true }
        return false
    }

    var body: some View {
        Group {
            if cleaner.isConnected {
                connected
            } else {
                intro
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
        .navigationTitle("Почта iCloud")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if cleaner.isConnected {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Отключить почту", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            confirmSignOut = true
                        }
                        .accessibilityIdentifier("mail.disconnect")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("mail.menu")
                    .disabled(cleaner.isBusy)
                }
            }
        }
        // Проверка за тот же период уже идёт или закончена (например, из умной чистки): заново не начинаем.
        .task { cleaner.scanIfNeeded(interval: interval) }
        .onChange(of: cleaner.isConnected) { _, connected in
            if connected { cleaner.scanIfNeeded(interval: interval) }
        }
        .onChange(of: period) { cleaner.scanIfNeeded(interval: interval) }
        .sheet(isPresented: $isConnecting) {
            MailConnectView(cleaner: cleaner)
        }
        .sheet(isPresented: $isPickingPeriod) {
            PeriodPickerView(selection: $period)
                .presentationDetents([.large])
        }
        .confirmationDialog("Очистить почту?", isPresented: $confirmClean, titleVisibility: .visible) {
            Button("Очистить (\(cleaner.selectedCount))", role: .destructive) {
                Task { await cleaner.clean() }
            }
            .accessibilityIdentifier("mail.confirmClean")
        } message: {
            Text(confirmMessage)
        }
        .confirmationDialog("Отключить почту?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Отключить", role: .destructive) { cleaner.signOut() }
                .accessibilityIdentifier("mail.confirmDisconnect")
        } message: {
            Text("Пароль приложения удалится из связки ключей iPhone. Отозвать его совсем можно на account.apple.com.")
        }
        .alert("Не получилось", isPresented: Binding(get: { cleaner.errorMessage != nil }, set: { if !$0 { cleaner.errorMessage = nil } })) {
            Button("OK") { cleaner.errorMessage = nil }
        } message: {
            Text(cleaner.errorMessage ?? "")
        }
    }

    private var confirmMessage: String {
        let permanent = cleaner.selected.filter(\.isPermanent).reduce(0) { $0 + cleaner.active(in: $1).count }
        let movable = cleaner.selectedCount - permanent
        var parts: [String] = []
        if permanent > 0 {
            parts.append(String(localized: "Навсегда из «Спама» и «Удалённых»: \(permanent), освободится около \(cleaner.selectedPermanentBytes.formattedBytes)."))
        }
        if movable > 0 {
            let movableBytes = cleaner.selectedBytes - cleaner.selectedPermanentBytes
            parts.append(String(localized: "В «Удалённые» (\(movableBytes.formattedBytes)), откуда можно вернуть в Почте: \(movable). Место освободится после очистки «Удалённых»."))
        }
        return parts.joined(separator: " ")
    }

    // MARK: - До подключения

    private var intro: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .frame(width: 54, height: 54)
                        .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Почта iCloud")
                            .font(.headline)
                        Text("Спам, рассылки и старые письма — одной кнопкой")
                            .font(.subheadline)
                            .opacity(0.9)
                    }
                    Spacer(minLength: 0)
                }
                .gradientCard(Tone.blue.gradient)

                // Три шага: пароль приложения создаётся у Apple один раз и дальше лежит в связке ключей.
                VStack(alignment: .leading, spacing: 16) {
                    introRow(symbol: "key.fill", tone: .green, title: "1. Создайте пароль приложения",
                             text: "Кнопка ниже откроет account.apple.com: «Вход и безопасность» → «Пароли приложений» → «+». Это не пароль Apple ID: он работает только для почты и отзывается в любой момент.")
                    introRow(symbol: "doc.on.doc.fill", tone: .indigo, title: "2. Скопируйте его",
                             text: "Apple покажет пароль вида xxxx-xxxx-xxxx-xxxx. Нажмите на него и выберите «Скопировать».")
                    introRow(symbol: "checkmark.shield.fill", tone: .blue, title: "3. Вставьте его здесь один раз",
                             text: "Пароль хранится в связке ключей iPhone и уходит только на imap.mail.me.com. Письма не открываются: приложение видит лишь отправителя, тему, дату и размер.")
                }
                .card()

                if let url = MailConnectView.appPasswordsURL {
                    Link(destination: url) {
                        Label("Создать пароль приложения", systemImage: "safari")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .tint(Tone.blue.color)
                    .accessibilityIdentifier("mail.createPassword")
                }

                Button("Подключить iCloud Mail") { isConnecting = true }
                    .buttonStyle(PrimaryButtonStyle(gradient: Tone.blue.gradient))
                    .accessibilityIdentifier("mail.connect")
            }
            .padding(16)
        }
    }

    private func introRow(symbol: String, tone: Tone, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ToneIcon(symbol: symbol, tone: tone, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Подключено

    private var connected: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    accountCard
                    periodRow
                    scanCard
                    if cleaner.state == .finished || cleaner.hasFindings {
                        categoryCards
                    }
                    safetyNote
                }
                .padding(16)
            }
            if cleaner.state == .finished, cleaner.hasFindings {
                Button("Очистить (\(cleaner.selectedCount))") { confirmClean = true }
                    .buttonStyle(PrimaryButtonStyle(gradient: Tone.blue.gradient))
                    .disabled(cleaner.selectedCount == 0)
                    .accessibilityIdentifier("mail.clean")
                    .padding(16)
                    .background(.bar)
            }
        }
        .disabled(isCleaning)
    }

    private var accountCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 54, height: 54)
                .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: cleaner.email ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let quota = cleaner.quota {
                    Text("Почта занимает \(quota.used.formattedBytes) из \(quota.limit.formattedBytes)")
                        .font(.subheadline)
                        .opacity(0.9)
                    GradientBar(value: quota.fraction, gradient: LinearGradient(colors: [.white, .white.opacity(0.75)], startPoint: .leading, endPoint: .trailing), height: 6)
                } else {
                    Text("iCloud Mail подключена")
                        .font(.subheadline)
                        .opacity(0.9)
                }
            }
            Spacer(minLength: 0)
        }
        .gradientCard(Tone.blue.gradient)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mail.account")
    }

    private var periodRow: some View {
        Button {
            isPickingPeriod = true
        } label: {
            HStack(spacing: 12) {
                ToneIcon(symbol: "calendar", tone: .indigo, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Период")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Чистим только письма, пришедшие в выбранный период.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Text(period.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.brandEnd)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .card(padding: 14)
        }
        .buttonStyle(.plain)
        .disabled(cleaner.isBusy)
        .accessibilityIdentifier("mail.period")
    }

    @ViewBuilder
    private var scanCard: some View {
        switch cleaner.state {
        case .idle:
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ToneIcon(symbol: "sparkle.magnifyingglass", tone: .blue, size: 44)
                    Text("Проверю папки «Спам», «Удалённые» и «Входящие» за выбранный период и разложу лишнее по категориям.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button("Проверить почту") { cleaner.scan(interval: interval) }
                    .buttonStyle(PrimaryButtonStyle(gradient: Tone.blue.gradient))
                    .accessibilityIdentifier("mail.scan")
            }
            .card()
        case .connecting:
            ProgressView("Подключаюсь к iCloud…")
                .frame(maxWidth: .infinity)
                .card()
        case let .scanning(done, total):
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ToneIcon(symbol: "sparkle.magnifyingglass", tone: .blue, size: 36)
                    Text("Проверяю почту")
                        .font(.headline)
                    Spacer()
                    Button("Отмена") { cleaner.cancel() }
                        .font(.subheadline)
                }
                GradientBar(value: total == 0 ? 0 : Double(done) / Double(total), gradient: Tone.blue.gradient)
                Text(total == 0 ? "Подключаюсь к iCloud…" as LocalizedStringKey : "Проверено \(done) из \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .card()
        case let .cleaning(done, total):
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ToneIcon(symbol: "trash.fill", tone: .blue, size: 36)
                    Text("Убираю лишнее")
                        .font(.headline)
                    Spacer()
                }
                GradientBar(value: total == 0 ? 0 : Double(done) / Double(total), gradient: Tone.blue.gradient)
                Text("Удалено \(done) из \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .card()
        case .finished:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ToneIcon(symbol: cleaner.hasFindings ? "sparkles" : "checkmark.seal.fill", tone: cleaner.hasFindings ? .blue : .green, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cleaner.hasFindings ? "Можно освободить" as LocalizedStringKey : "Лишних писем нет")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if cleaner.hasFindings {
                            Text(cleaner.totalBytes.formattedBytes)
                                .font(.title2.bold().monospacedDigit())
                                .contentTransition(.numericText())
                        }
                    }
                    Spacer()
                    Button("Проверить заново", systemImage: "arrow.clockwise") { cleaner.scan(interval: interval) }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .accessibilityIdentifier("mail.rescan")
                }
                if let report = cleaner.report {
                    Label(report.summary, systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Tone.green.color)
                        .accessibilityIdentifier("mail.report")
                }
            }
            .card()
        }
    }

    private var categoryCards: some View {
        VStack(spacing: 12) {
            ForEach(MailCategory.allCases) { category in
                if !cleaner.messages(in: category).isEmpty {
                    categoryCard(category)
                }
            }
        }
    }

    private func categoryCard(_ category: MailCategory) -> some View {
        let total = cleaner.messages(in: category).count
        let count = cleaner.active(in: category).count
        let isOn = cleaner.selected.contains(category)
        return HStack(spacing: 12) {
            // Ссылка с готовым экраном, а не со значением: стек главной держит путь из HomeRoute,
            // и navigationDestination для другого типа внутри него не сработал бы.
            NavigationLink {
                MailMessagesView(category: category, cleaner: cleaner)
            } label: {
                HStack(spacing: 12) {
                    ToneIcon(symbol: category.symbol, tone: category.tone, size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(category.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(countText(total: total, active: count, bytes: cleaner.bytes(in: category)))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(category.actionHint)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(category.isPermanent ? Tone.red.color : Tone.green.color)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mail.category.\(category.rawValue)")

            Toggle(isOn: Binding(get: { isOn }, set: { cleaner.setSelected(category, $0) })) {
                Text(category.title)
            }
            .labelsHidden()
            .tint(category.tone.color)
            .accessibilityIdentifier("mail.toggle.\(category.rawValue)")
        }
        .card(padding: 14)
        .opacity(isOn ? 1 : 0.7)
    }

    /// «Писем: 5 · 1,2 МБ», а если часть снята с чистки в списке — «Писем: 5, к чистке: 3 · 800 КБ».
    private func countText(total: Int, active: Int, bytes: Int64) -> LocalizedStringKey {
        if active == total {
            return "Писем: \(total) · \(bytes.formattedBytes)"
        }
        return "Писем: \(total), к чистке: \(active) · \(bytes.formattedBytes)"
    }

    private var safetyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(Tone.green.color)
            Text("Письма не открываются: приложение видит только отправителя, тему, дату и размер. Ссылки и вложения не загружаются, поэтому фишинг безопасен.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

/// Список писем одной категории. Текст показывается как есть, без ссылок и без открытия письма:
/// нажатие только снимает письмо с чистки или возвращает его.
struct MailMessagesView: View {
    let category: MailCategory
    let cleaner: MailCleaner

    private var messages: [MailMessage] {
        cleaner.messages(in: category)
    }

    private var isAllIncluded: Bool {
        messages.allSatisfy { cleaner.isIncluded($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ToneIcon(symbol: category.symbol, tone: category.tone, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.detail)
                            .font(.subheadline)
                        Text(category.actionHint)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(category.isPermanent ? Tone.red.color : Tone.green.color)
                    }
                }
                .card(padding: 14)
                if messages.isEmpty {
                    ContentUnavailableView("Писем не осталось", systemImage: "checkmark.seal")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(messages) { message in
                            row(message)
                            if message.id != messages.last?.id {
                                Divider().padding(.leading, 48)
                            }
                        }
                    }
                    .card(padding: 12)
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !messages.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isAllIncluded ? "Снять все" as LocalizedStringKey : "Выбрать все") {
                        cleaner.setAllIncluded(!isAllIncluded, in: category)
                    }
                    .accessibilityIdentifier("mail.toggleAll")
                }
            }
        }
    }

    private func row(_ message: MailMessage) -> some View {
        let isIncluded = cleaner.isIncluded(message)
        return Button {
            cleaner.toggle(message)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isIncluded ? category.tone.color : Color(.tertiaryLabel))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: message.displaySender)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(verbatim: message.size.formattedBytes)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: message.displaySubject)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(verbatim: "\(message.senderAddress) · \(message.date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isIncluded ? .isSelected : [])
        .accessibilityIdentifier("mail.message")
    }
}

extension MailCleaner.Report {
    /// «Удалено писем: 6 · освобождено 1,2 МБ» или, если всё ушло в «Удалённые», «В «Удалённые»: 6 писем · 1,2 МБ».
    var summary: LocalizedStringKey {
        if freed > 0 {
            return "Удалено писем: \(count) · освобождено \(freed.formattedBytes)"
        }
        return "В «Удалённые»: \(count) писем · \(moved.formattedBytes)"
    }
}
