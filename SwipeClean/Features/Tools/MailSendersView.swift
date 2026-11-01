import SwiftUI

/// Отправители писем из «Входящих»: у кого сколько писем и сколько места они занимают.
/// Отмеченных отправителей можно разом перенести в корзину почты («Удалённые» у iCloud, «Корзина» у Gmail), а открыв отправителя — посмотреть его письма.
/// Письма по-прежнему не открываются: видны только отправитель, тема, дата и размер.
struct MailSendersView: View {
    let cleaner: MailCleaner
    @AppStorage(SettingsKeys.mailSenderSort) private var sort = MailSenderSort.count
    @State private var query = ""
    @State private var picked: Set<String> = []
    @State private var confirmDelete = false
    /// Отчёт показывается, только если чистка запущена с этого экрана.
    @State private var showsReport = false

    private var visible: [MailSender] {
        let sorted = sort.sorted(cleaner.senders)
        return query.isEmpty ? sorted : sorted.filter { MailSenderGrouper.matches($0, query: query) }
    }

    /// Отмеченные отправители, которые ещё есть в списке: ушедшие после чистки выпадают сами.
    private var pickedSenders: [MailSender] {
        cleaner.senders.filter { picked.contains($0.id) }
    }

    private var pickedMessages: [MailMessage] {
        pickedSenders.flatMap { cleaner.active(from: $0) }
    }

    var body: some View {
        let chosen = pickedMessages
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    MailCleanStatus(cleaner: cleaner, showsReport: showsReport)
                    if cleaner.senders.isEmpty {
                        ContentUnavailableView("Писем не осталось", systemImage: "checkmark.seal")
                    } else if visible.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(visible) { sender in
                                row(sender)
                                if sender.id != visible.last?.id {
                                    Divider().padding(.leading, 92)
                                }
                            }
                        }
                        .card(padding: 12)
                    }
                }
                .padding(16)
            }
            if !chosen.isEmpty {
                Button("В корзину: \(chosen.count)") { confirmDelete = true }
                    .buttonStyle(PrimaryButtonStyle(gradient: Tone.violet.gradient))
                    .accessibilityIdentifier("mail.senders.delete")
                    .padding(16)
                    .background(.bar)
            }
        }
        .disabled(cleaner.isCleaning)
        .screenBackground()
        .navigationTitle("Отправители")
        .navigationBarTitleDisplayMode(.inline)
        // Поле поиска всегда видно под заголовком: в iOS 26+ без явного места оно прячется в кнопку.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Имя или адрес")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Сортировка", selection: $sort) {
                        ForEach(MailSenderSort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Label("Сортировка", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier("mail.senders.sort")
            }
        }
        .confirmationDialog("Перенести в корзину?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Перенести (\(chosen.count))", role: .destructive) {
                let addresses = picked
                showsReport = true
                Task {
                    await cleaner.cleanSenders(addresses)
                    picked.subtract(addresses)
                }
            }
            .accessibilityIdentifier("mail.senders.confirmDelete")
        } message: {
            Text(MailSendersView.moveMessage(count: chosen.count, senders: pickedSenders.count, bytes: chosen.reduce(Int64(0)) { $0 + $1.size }))
        }
    }

    /// Текст подтверждения: сколько писем уйдёт и что их можно вернуть.
    static func moveMessage(count: Int, senders: Int, bytes: Int64) -> String {
        let what = senders > 1
            ? String(localized: "Отправителей: \(senders), писем: \(count), \(bytes.formattedBytes).")
            : String(localized: "Писем: \(count), \(bytes.formattedBytes).")
        return what + " " + String(localized: "Их можно вернуть в почте, пока корзина не очищена. Место освободится после её очистки.")
    }

    private var header: some View {
        HStack(spacing: 12) {
            ToneIcon(symbol: "person.2.fill", tone: .violet, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Отметьте ненужных отправителей, чтобы убрать всё от них разом, или откройте отправителя и посмотрите письма.")
                    .font(.subheadline)
                Text("Переедут в корзину почты")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Tone.green.color)
            }
        }
        .card(padding: 14)
    }

    private func row(_ sender: MailSender) -> some View {
        let isPicked = picked.contains(sender.id)
        let active = cleaner.active(from: sender)
        return HStack(spacing: 8) {
            Button {
                if isPicked { picked.remove(sender.id) } else { picked.insert(sender.id) }
            } label: {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isPicked ? Tone.violet.color : Color(.tertiaryLabel))
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: sender.displayName))
            .accessibilityAddTraits(isPicked ? .isSelected : [])
            .accessibilityIdentifier("mail.sender.pick")

            // Ссылка с готовым экраном, а не со значением: стек главной держит путь из HomeRoute.
            NavigationLink {
                MailSenderDetailView(address: sender.id, cleaner: cleaner)
            } label: {
                HStack(spacing: 12) {
                    MailSenderAvatar(sender: sender, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: sender.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if sender.isBulk {
                                Text("Рассылка")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Tone.pink.color)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Tone.pink.color.opacity(0.14), in: Capsule())
                            }
                        }
                        if !sender.name.isEmpty {
                            Text(verbatim: sender.address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: "\(active.count)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.primary)
                        Text(verbatim: active.reduce(Int64(0)) { $0 + $1.size }.formattedBytes)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mail.sender")
        }
    }
}

/// Письма одного отправителя. Нажатие на письмо снимает его с чистки, кнопка внизу переносит остальные в корзину почты.
struct MailSenderDetailView: View {
    let address: String
    let cleaner: MailCleaner
    @State private var confirmDelete = false
    @State private var showsReport = false

    private var sender: MailSender? {
        cleaner.sender(address)
    }

    var body: some View {
        let messages = sender?.messages ?? []
        let active = sender.map { cleaner.active(from: $0) } ?? []
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let sender {
                        header(sender, active: active)
                    }
                    MailCleanStatus(cleaner: cleaner, showsReport: showsReport)
                    if messages.isEmpty {
                        ContentUnavailableView("Писем не осталось", systemImage: "checkmark.seal")
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(messages) { message in
                                MailMessageRow(message: message, cleaner: cleaner, tone: .violet, showsSender: false)
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
            if !active.isEmpty {
                Button("В корзину: \(active.count)") { confirmDelete = true }
                    .buttonStyle(PrimaryButtonStyle(gradient: Tone.violet.gradient))
                    .accessibilityIdentifier("mail.sender.delete")
                    .padding(16)
                    .background(.bar)
            }
        }
        .disabled(cleaner.isCleaning)
        .screenBackground()
        .navigationTitle(sender?.displayName ?? address)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let sender, !messages.isEmpty {
                let isAllIncluded = active.count == messages.count
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isAllIncluded ? "Снять все" as LocalizedStringKey : "Выбрать все") {
                        cleaner.setAllIncluded(!isAllIncluded, from: sender)
                    }
                    .accessibilityIdentifier("mail.sender.toggleAll")
                }
            }
        }
        .confirmationDialog("Перенести в корзину?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Перенести (\(active.count))", role: .destructive) {
                showsReport = true
                Task { await cleaner.cleanSenders([address]) }
            }
            .accessibilityIdentifier("mail.sender.confirmDelete")
        } message: {
            Text(MailSendersView.moveMessage(count: active.count, senders: 1, bytes: active.reduce(Int64(0)) { $0 + $1.size }))
        }
    }

    private func header(_ sender: MailSender, active: [MailMessage]) -> some View {
        HStack(spacing: 12) {
            MailSenderAvatar(sender: sender, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: sender.displayName)
                    .font(.headline)
                    .lineLimit(1)
                if !sender.name.isEmpty {
                    Text(verbatim: sender.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(countText(total: sender.count, active: active.count, bytes: active.reduce(Int64(0)) { $0 + $1.size }))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mail.sender.header")
    }

    private func countText(total: Int, active: Int, bytes: Int64) -> LocalizedStringKey {
        if active == total {
            return "Писем: \(total) · \(bytes.formattedBytes)"
        }
        return "Писем: \(total), к чистке: \(active) · \(bytes.formattedBytes)"
    }
}

/// Кружок с первой буквой отправителя. Цвет постоянный для адреса.
struct MailSenderAvatar: View {
    let sender: MailSender
    var size: CGFloat = 40

    var body: some View {
        Text(verbatim: sender.initial)
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(sender.tone.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Строка письма: текст как есть, без ссылок и без открытия письма. Нажатие снимает письмо с чистки или возвращает его.
struct MailMessageRow: View {
    let message: MailMessage
    let cleaner: MailCleaner
    let tone: Tone
    var showsSender = true

    var body: some View {
        let isIncluded = cleaner.isIncluded(message)
        Button {
            cleaner.toggle(message)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isIncluded ? tone.color : Color(.tertiaryLabel))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    if showsSender {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: message.displaySender)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            size
                        }
                        Text(verbatim: message.displaySubject)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(verbatim: details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: message.displaySubject)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            size
                        }
                        Text(verbatim: dateDetails)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isIncluded ? .isSelected : [])
        .accessibilityIdentifier("mail.message")
    }

    /// Из какого ящика письмо: видно, только если подключено несколько.
    private var accountPrefix: String {
        cleaner.accounts.count > 1 ? "\(message.account.title) · " : ""
    }

    private var date: String {
        message.date.formatted(date: .abbreviated, time: .omitted)
    }

    private var details: String {
        "\(accountPrefix)\(message.senderAddress) · \(date)"
    }

    private var dateDetails: String {
        "\(accountPrefix)\(date)"
    }

    private var size: some View {
        Text(verbatim: message.size.formattedBytes)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// Ход и итог чистки на экранах отправителей: экран почты в это время скрыт под ними.
struct MailCleanStatus: View {
    let cleaner: MailCleaner
    let showsReport: Bool

    var body: some View {
        if case let .cleaning(done, total) = cleaner.state {
            VStack(alignment: .leading, spacing: 10) {
                Text("Переношу в корзину")
                    .font(.headline)
                GradientBar(value: total == 0 ? 0 : Double(done) / Double(total), gradient: Tone.violet.gradient)
                Text("Готово \(done) из \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .card(padding: 14)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("mail.senders.progress")
        } else if showsReport, let report = cleaner.report {
            Label(report.summary, systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Tone.green.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 14)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("mail.senders.report")
        }
        if showsReport, let message = cleaner.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tone.red.color)
                Text(verbatim: message)
                    .font(.footnote)
                Spacer(minLength: 0)
                Button("Понятно") { cleaner.errorMessage = nil }
                    .font(.footnote.weight(.semibold))
            }
            .card(padding: 14)
            .accessibilityIdentifier("mail.senders.error")
        }
    }
}
