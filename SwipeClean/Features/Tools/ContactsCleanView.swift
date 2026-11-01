import SwiftUI

/// Чистка контактов: объединение дублей, удаление контактов без номера и почты, контакты без имени.
/// Перед объединением и удалением сохраняется резервная копия, последнее действие можно отменить.
struct ContactsCleanView: View {
    enum Part: String, CaseIterable, Identifiable {
        case duplicates
        case incomplete
        case unnamed

        var id: String { rawValue }
    }

    @Environment(PhotoLibraryService.self) private var library
    @State private var cleaner = ContactsCleaner()
    @State private var section = Part.duplicates
    @State private var selection: Set<String> = []
    @State private var isWorking = false
    @State private var confirmMergeAll = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?
    /// Копия перед последним объединением или удалением: для кнопки «Отменить».
    @State private var lastBackup: ContactsBackup?

    /// Сколько контактов уйдёт после объединения дублей и удаления пустых.
    private var extraCount: Int {
        cleaner.duplicates.reduce(0) { $0 + $1.count - 1 } + cleaner.incomplete.count
    }

    private var list: [ContactCard] {
        section == .incomplete ? cleaner.incomplete : cleaner.unnamed
    }

    /// Плашка отмены видна, пока последнюю копию не восстановили (в том числе с экрана копий).
    private var undoBackup: ContactsBackup? {
        guard let lastBackup else { return nil }
        return cleaner.backups.items.first { $0.id == lastBackup.id && $0.restoredAt == nil }
    }

    var body: some View {
        Group {
            switch cleaner.access {
            case .denied:
                ContentUnavailableView {
                    Label("Нет доступа к контактам", systemImage: "person.crop.circle.badge.xmark")
                } description: {
                    Text("Разрешите доступ в Настройках, чтобы найти дубли и пустые контакты.")
                } actions: {
                    Button("Открыть Настройки") { library.openSettings() }
                        .buttonStyle(.borderedProminent)
                }
            case .unknown, .granted:
                if cleaner.isLoading && cleaner.cards.isEmpty {
                    ProgressView("Ищу дубли…")
                } else {
                    content
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
        .navigationTitle("Контакты")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if section != .duplicates, !list.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selection.count == list.count ? "Снять все" as LocalizedStringKey : "Выбрать все") {
                        selection = selection.count == list.count ? [] : Set(list.map(\.id))
                    }
                    .accessibilityIdentifier("contacts.toggleAll")
                }
            }
        }
        .task { await cleaner.requestAccessAndLoad() }
        .onChange(of: section) { selection.removeAll() }
        .confirmationDialog("Объединить все дубли?", isPresented: $confirmMergeAll, titleVisibility: .visible) {
            Button("Объединить (\(cleaner.duplicates.count))") { merge(cleaner.duplicates) }
                .accessibilityIdentifier("contacts.confirmMerge")
        } message: {
            Text("В каждой группе останется самый полный контакт, к нему добавятся номера, почта и адреса остальных. Перед объединением сохранится резервная копия.")
        }
        .confirmationDialog("Удалить выбранные контакты?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить (\(selection.count))", role: .destructive, action: deleteSelected)
                .accessibilityIdentifier("contacts.confirmDelete")
        } message: {
            Text("Перед удалением сохранится резервная копия: удалённые контакты можно будет вернуть.")
        }
        .alert("Не получилось", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    backupsLink
                    Picker("Раздел", selection: $section) {
                        Text("Дубли (\(cleaner.duplicates.count))").tag(Part.duplicates)
                        Text("Без номера (\(cleaner.incomplete.count))").tag(Part.incomplete)
                        Text("Без имени (\(cleaner.unnamed.count))").tag(Part.unnamed)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("contacts.section")

                    switch section {
                    case .duplicates: duplicatesList
                    case .incomplete, .unnamed: selectableList
                    }
                }
                .padding(16)
            }
            if let backup = undoBackup {
                undoBar(backup)
            }
            bottomBar
        }
        .disabled(isWorking)
    }

    private var backupsLink: some View {
        NavigationLink {
            ContactsBackupsView(cleaner: cleaner)
        } label: {
            HStack(spacing: 12) {
                ToneIcon(symbol: "clock.arrow.circlepath", tone: .teal, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Резервные копии")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Group {
                        if let last = cleaner.backups.items.first {
                            Text("Последняя: \(last.date, format: .dateTime.day().month().hour().minute())")
                        } else {
                            Text("Сохраняются перед объединением и удалением")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .card(padding: 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("contacts.backups")
    }

    /// Плашка после объединения или удаления: копия сохранена, действие можно отменить.
    private func undoBar(_ backup: ContactsBackup) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.title3)
                .foregroundStyle(Tone.green.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(backup.kind == .merge ? "Контакты объединены" as LocalizedStringKey : "Контакты удалены")
                    .font(.subheadline.weight(.semibold))
                Text("Копия сохранена в «Резервных копиях»")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Отменить") { undo(backup) }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Tone.cyan.color)
                .accessibilityIdentifier("contacts.undo")
            Button {
                lastBackup = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Скрыть")
            .accessibilityIdentifier("contacts.undoClose")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 54, height: 54)
                .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Контактов: \(cleaner.cards.count)")
                    .font(.headline)
                Text("Лишних: \(extraCount)")
                    .font(.subheadline)
                    .opacity(0.9)
            }
            Spacer(minLength: 0)
        }
        .gradientCard(Tone.cyan.gradient)
    }

    @ViewBuilder
    private var duplicatesList: some View {
        if cleaner.duplicates.isEmpty {
            ContentUnavailableView("Дублей нет", systemImage: "checkmark.seal", description: Text("Контакты с одинаковыми именами, номерами или почтой не найдены."))
        } else {
            ForEach(cleaner.duplicates, id: \.first?.id) { group in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(group.enumerated()), id: \.element.id) { index, card in
                        HStack(alignment: .top, spacing: 10) {
                            ContactAvatar(card: card, tone: index == 0 ? .cyan : .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Text(card.details)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            if index == 0 {
                                Text("Останется")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Tone.green.color)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Tone.green.color.opacity(0.14), in: Capsule())
                            }
                        }
                    }
                    Button("Объединить") { merge([group]) }
                        .buttonStyle(TintedButtonStyle(tint: Tone.cyan.color))
                        .accessibilityIdentifier("contacts.merge")
                }
                .card()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("contacts.group")
            }
        }
    }

    @ViewBuilder
    private var selectableList: some View {
        if list.isEmpty {
            ContentUnavailableView(
                "Таких контактов нет",
                systemImage: "checkmark.seal",
                description: Text(section == .incomplete
                                  ? "У всех контактов есть номер или почта." as LocalizedStringKey
                                  : "У всех контактов есть имя или компания.")
            )
        } else {
            VStack(spacing: 0) {
                ForEach(list) { card in
                    let isSelected = selection.contains(card.id)
                    Button {
                        if isSelected { selection.remove(card.id) } else { selection.insert(card.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? Tone.cyan.color : Color(.tertiaryLabel))
                            ContactAvatar(card: card, tone: .cyan)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if !card.details.isEmpty {
                                    Text(card.details)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("contacts.row")
                    if card.id != list.last?.id {
                        Divider().padding(.leading, 84)
                    }
                }
            }
            .card(padding: 12)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        switch section {
        case .duplicates:
            if cleaner.duplicates.count > 1 {
                Button("Объединить все (\(cleaner.duplicates.count))") { confirmMergeAll = true }
                    .buttonStyle(PrimaryButtonStyle(gradient: Tone.cyan.gradient))
                    .accessibilityIdentifier("contacts.mergeAll")
                    .padding(16)
                    .background(.bar)
            }
        case .incomplete, .unnamed:
            if !list.isEmpty {
                Button("Удалить (\(selection.count))") { confirmDelete = true }
                    .buttonStyle(PrimaryButtonStyle(gradient: Tone.red.gradient))
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("contacts.delete")
                    .padding(16)
                    .background(.bar)
            }
        }
    }

    private func merge(_ groups: [[ContactCard]]) {
        isWorking = true
        Task {
            do {
                lastBackup = try await cleaner.merge(groups)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func deleteSelected() {
        let ids = selection
        isWorking = true
        Task {
            do {
                lastBackup = try await cleaner.delete(ids)
                selection.removeAll()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func undo(_ backup: ContactsBackup) {
        isWorking = true
        Task {
            do {
                try await cleaner.restore(backup)
                lastBackup = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

private extension ContactCard {
    /// Телефоны и почта одной строкой для подписи.
    var details: String {
        (phones + emails).joined(separator: " · ")
    }
}

/// Кружок с инициалами контакта.
private struct ContactAvatar: View {
    let card: ContactCard
    let tone: Tone

    private var initials: String {
        let words = card.displayName.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(tone.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}
