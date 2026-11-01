import SwiftUI

/// Резервные копии контактов: автоматические перед объединением и удалением и полная копия по кнопке.
/// Из копии можно вернуть контакты или сохранить её файлом .vcf в «Файлы», почту, AirDrop.
struct ContactsBackupsView: View {
    let cleaner: ContactsCleaner

    @State private var restoring: ContactsBackup?
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var backups: [ContactsBackup] { cleaner.backups.items }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                Button {
                    backUpAll()
                } label: {
                    Label("Сохранить копию всех контактов", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(TintedButtonStyle(tint: Tone.teal.color))
                .accessibilityIdentifier("backups.makeFull")

                if backups.isEmpty {
                    ContentUnavailableView(
                        "Копий пока нет",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Копия появится при первом объединении или удалении контактов.")
                    )
                } else {
                    ForEach(backups) { backup in
                        BackupCard(backup: backup, url: cleaner.backups.fileURL(for: backup)) {
                            restoring = backup
                        } onDelete: {
                            cleaner.backups.delete(backup)
                        }
                    }
                }

                Text("Заметки контактов iOS не отдаёт приложениям, поэтому в копию они не попадают. Копии хранятся на iPhone; чтобы не потерять их вместе с приложением, сохраните файл .vcf в «Файлы».")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView()
                    .controlSize(.large)
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .screenBackground()
        .navigationTitle("Резервные копии")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Вернуть контакты из копии?",
            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
            titleVisibility: .visible,
            presenting: restoring
        ) { backup in
            Button("Восстановить") { restore(backup) }
                .accessibilityIdentifier("backups.confirmRestore")
        } message: { backup in
            Text(backup.restoreHint)
        }
        .alert("Не получилось", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 54, height: 54)
                .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Копий: \(backups.count)")
                    .font(.headline)
                Text("Перед каждым объединением и удалением контакты сохраняются в файл vCard.")
                    .font(.subheadline)
                    .opacity(0.9)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .gradientCard(Tone.teal.gradient)
    }

    private func restore(_ backup: ContactsBackup) {
        isWorking = true
        Task {
            do {
                try await cleaner.restore(backup)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func backUpAll() {
        isWorking = true
        Task {
            do {
                try await cleaner.backUpAll()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// Карточка копии: когда и зачем сделана, кто в ней, кнопки «Восстановить» и «Поделиться».
private struct BackupCard: View {
    let backup: ContactsBackup
    let url: URL
    let onRestore: () -> Void
    let onDelete: () -> Void

    /// Первые имена из копии; полная копия показывает только количество.
    private var names: String {
        guard backup.kind != .full else { return "" }
        let shown = backup.entries.prefix(4).map(\.name).joined(separator: ", ")
        return backup.entries.count > 4 ? shown + "…" : shown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ToneIcon(symbol: backup.symbol, tone: backup.tone, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(backup.title)
                        .font(.subheadline.weight(.semibold))
                    Text("\(backup.date, format: .dateTime.day().month().year().hour().minute()) · контактов: \(backup.entries.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !names.isEmpty {
                        Text(names)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    Button(role: .destructive, action: onDelete) {
                        Label("Удалить копию", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Ещё")
                .accessibilityIdentifier("backups.more")
            }

            HStack(spacing: 10) {
                if backup.restoredAt != nil {
                    Label("Восстановлено", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Tone.green.color)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("backups.restored")
                } else {
                    Button("Восстановить", action: onRestore)
                        .buttonStyle(TintedButtonStyle(tint: Tone.cyan.color))
                        .accessibilityIdentifier("backups.restore")
                }
                ShareLink(item: url, preview: SharePreview(backup.fileName)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline)
                        .frame(width: 52, height: 52)
                        .background(Tone.teal.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(Tone.teal.color)
                }
                .accessibilityLabel("Сохранить файл .vcf")
                .accessibilityIdentifier("backups.share")
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("backups.item")
    }
}

private extension ContactsBackup {
    var title: LocalizedStringKey {
        switch kind {
        case .merge: "Перед объединением"
        case .delete: "Перед удалением"
        case .full: "Все контакты"
        }
    }

    var symbol: String {
        switch kind {
        case .merge: "arrow.triangle.merge"
        case .delete: "trash"
        case .full: "person.crop.rectangle.stack"
        }
    }

    var tone: Tone {
        switch kind {
        case .merge: .cyan
        case .delete: .red
        case .full: .indigo
        }
    }

    var restoreHint: LocalizedStringKey {
        switch kind {
        case .merge: "Удалённые при объединении контакты вернутся, а основной контакт станет таким, каким был до объединения."
        case .delete: "Удалённые контакты вернутся в адресную книгу."
        case .full: "Вернутся контакты из копии, которых сейчас нет в адресной книге. Остальные не изменятся."
        }
    }
}
