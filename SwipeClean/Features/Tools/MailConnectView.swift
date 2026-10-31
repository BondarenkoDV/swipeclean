import SwiftUI

/// Подключение iCloud Mail: адрес и пароль приложения. Пароль уходит только на imap.mail.me.com
/// и сохраняется в связке ключей, если iCloud его принял.
struct MailConnectView: View {
    let cleaner: MailCleaner
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    /// Страница Apple, где создают пароли приложений.
    static let appPasswordsURL = URL(string: "https://account.apple.com/account/manage/section/security")

    private var canConnect: Bool {
        email.contains("@") && password.trimmingCharacters(in: .whitespaces).count >= 8 && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Адрес iCloud", text: $email, prompt: Text(verbatim: "name@icloud.com"))
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("mail.email")
                    HStack {
                        SecureField("Пароль приложения", text: $password, prompt: Text(verbatim: "xxxx-xxxx-xxxx-xxxx"))
                            .textContentType(.password)
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
                    Text("1. Создайте пароль приложения кнопкой ниже. 2. Скопируйте его. 3. Вставьте сюда. Нужен именно пароль приложения, а не пароль Apple ID; для него у Apple ID должна быть включена двухфакторная аутентификация.")
                }

                Section {
                    if let url = Self.appPasswordsURL {
                        Link(destination: url) {
                            Label("Создать пароль приложения", systemImage: "safari")
                        }
                        .accessibilityIdentifier("mail.createPasswordLink")
                    }
                } footer: {
                    Text("Пароль отправляется только на imap.mail.me.com по защищённому соединению и хранится в связке ключей этого iPhone. Отозвать его можно в любой момент на account.apple.com.")
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
            .navigationTitle("Подключить iCloud Mail")
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

    private func connect() {
        isWorking = true
        Task {
            do {
                try await cleaner.signIn(email: email, password: password)
                dismiss()
            } catch {
                errorMessage = (error as? MailError)?.errorDescription ?? error.localizedDescription
            }
            isWorking = false
        }
    }
}
