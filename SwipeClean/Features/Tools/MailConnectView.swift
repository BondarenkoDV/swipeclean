import SwiftUI

/// Подключение ящика iCloud Mail или Gmail: адрес и пароль приложения. Пароль уходит только на сервер
/// выбранного сервиса (imap.mail.me.com или imap.gmail.com) и сохраняется в связке ключей, если сервер его принял.
struct MailConnectView: View {
    let provider: MailProvider
    let cleaner: MailCleaner
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field {
        case email, password
    }

    init(provider: MailProvider = .icloud, cleaner: MailCleaner) {
        self.provider = provider
        self.cleaner = cleaner
    }

    private var canConnect: Bool {
        email.contains("@") && provider.normalizedPassword(password).count >= 8 && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                // Три шага: пароль приложения создаётся один раз и дальше лежит в связке ключей.
                Section {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        stepRow(step)
                    }
                    if let url = provider.appPasswordsURL {
                        Link(destination: url) {
                            Label("Создать пароль приложения", systemImage: "safari")
                        }
                        .accessibilityIdentifier("mail.createPasswordLink")
                    }
                }

                Section {
                    TextField("Адрес \(provider.title)", text: $email, prompt: Text(verbatim: provider.emailPlaceholder))
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier("mail.email")
                    HStack {
                        SecureField("Пароль приложения", text: $password, prompt: Text(verbatim: provider.passwordPlaceholder))
                            .textContentType(.password)
                            .focused($focus, equals: .password)
                            .submitLabel(.go)
                            // «Готово» на клавиатуре сразу подключает: кнопку внизу формы может закрыть клавиатура.
                            .onSubmit { if canConnect { connect() } }
                            .accessibilityIdentifier("mail.password")
                        // Системная кнопка вставки: iOS не спрашивает разрешения, потому что нажимает сам пользователь.
                        PasteButton(payloadType: String.self) { strings in
                            guard let value = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
                            Task { @MainActor in password = value }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.capsule)
                        .accessibilityIdentifier("mail.paste")
                    }
                } footer: {
                    Text(privacyNote)
                }

                Section {
                    Button(action: connect) {
                        HStack {
                            Spacer()
                            if isWorking {
                                ProgressView()
                            } else {
                                Text("Подключить")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canConnect)
                    .accessibilityIdentifier("mail.signIn")
                }
            }
            .navigationTitle("Подключить \(provider.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .disabled(isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
            .alert("Не получилось", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Шаги

    private struct Step {
        let symbol: String
        let tone: Tone
        let title: LocalizedStringKey
        let text: LocalizedStringKey
    }

    private var steps: [Step] {
        switch provider {
        case .icloud:
            [
                Step(symbol: "key.fill", tone: .green, title: "1. Создайте пароль приложения",
                     text: "Кнопка ниже откроет account.apple.com: «Вход и безопасность» → «Пароли приложений» → «+». Это не пароль Apple ID: он работает только для почты и отзывается в любой момент. Нужна двухфакторная аутентификация Apple ID."),
                Step(symbol: "doc.on.doc.fill", tone: .indigo, title: "2. Скопируйте его",
                     text: "Apple покажет пароль вида xxxx-xxxx-xxxx-xxxx. Нажмите на него и выберите «Скопировать»."),
                Step(symbol: "checkmark.shield.fill", tone: .blue, title: "3. Вставьте его здесь один раз",
                     text: "Пароль хранится в связке ключей iPhone. Письма не открываются: приложение видит лишь отправителя, тему, дату и размер."),
            ]
        case .gmail:
            [
                Step(symbol: "lock.shield.fill", tone: .orange, title: "1. Включите двухэтапную аутентификацию",
                     text: "Без неё Google не даёт создать пароль приложения: myaccount.google.com → «Безопасность» → «Двухэтапная аутентификация». Если она уже включена, переходите к шагу 2."),
                Step(symbol: "key.fill", tone: .green, title: "2. Создайте пароль приложения",
                     text: "Кнопка ниже откроет myaccount.google.com/apppasswords. Введите любое название, например SwipeClean, и нажмите «Создать». Это не пароль Google: он работает только для почты и отзывается в любой момент."),
                Step(symbol: "doc.on.doc.fill", tone: .red, title: "3. Скопируйте и вставьте сюда",
                     text: "Google покажет 16 букв четырьмя группами. Пробелы убирать не нужно: приложение уберёт их само. После смены пароля Google пароль приложения перестаёт работать, тогда создайте новый."),
            ]
        }
    }

    private func stepRow(_ step: Step) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ToneIcon(symbol: step.symbol, tone: step.tone, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                Text(step.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var privacyNote: String {
        String(localized: "Пароль отправляется только на \(provider.host) по защищённому соединению и хранится в связке ключей этого iPhone. Отозвать его можно в любой момент на \(provider.accountSite).")
    }

    private func connect() {
        guard !isWorking else { return }
        focus = nil
        isWorking = true
        Task {
            do {
                try await cleaner.signIn(provider: provider, email: email, password: password)
                dismiss()
            } catch {
                errorMessage = (error as? MailError)?.message(for: provider) ?? error.localizedDescription
            }
            isWorking = false
        }
    }
}
