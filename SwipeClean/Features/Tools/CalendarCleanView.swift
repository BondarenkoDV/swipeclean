import SwiftUI

/// Чистка календаря: прошедшие события старше выбранного срока, сгруппированные по годам.
struct CalendarCleanView: View {
    @Environment(PhotoLibraryService.self) private var library
    @AppStorage(SettingsKeys.eventAge) private var age = EventAge.year
    @State private var cleaner = CalendarCleaner()
    @State private var selection: Set<String> = []
    @State private var isWorking = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    private struct YearGroup: Identifiable {
        let year: Int
        let events: [PastEvent]
        var id: Int { year }
    }

    private var byYear: [YearGroup] {
        let calendar = Calendar.current
        return Dictionary(grouping: cleaner.events) { calendar.component(.year, from: $0.start) }
            .map { YearGroup(year: $0.key, events: $0.value) }
            .sorted { $0.year > $1.year }
    }

    private var isAllSelected: Bool {
        !cleaner.events.isEmpty && selection.count == cleaner.events.count
    }

    var body: some View {
        Group {
            switch cleaner.access {
            case .denied:
                ContentUnavailableView {
                    Label("Нет доступа к календарю", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text("Разрешите полный доступ к календарю в Настройках, чтобы найти старые события.")
                } actions: {
                    Button("Открыть Настройки") { library.openSettings() }
                        .buttonStyle(.borderedProminent)
                }
            case .unknown, .granted:
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
        .navigationTitle("Календарь")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !cleaner.events.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isAllSelected ? "Снять все" as LocalizedStringKey : "Выбрать все") {
                        selection = isAllSelected ? [] : Set(cleaner.events.map(\.id))
                    }
                    .accessibilityIdentifier("calendar.toggleAll")
                }
            }
        }
        .task(id: age) {
            selection.removeAll()
            await cleaner.requestAccessAndLoad(age: age)
        }
        .confirmationDialog("Удалить выбранные события?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить (\(selection.count))", role: .destructive, action: deleteSelected)
                .accessibilityIdentifier("calendar.confirmDelete")
        } message: {
            Text("События удалятся на всех устройствах с этим календарём. «Недавно удалённых» у календаря нет.")
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
                VStack(alignment: .leading, spacing: 14) {
                    header
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(EventAge.allCases) { option in
                                let isSelected = option == age
                                Button(option.title) { age = option }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(isSelected ? .white : .primary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background {
                                        Capsule().fill(isSelected ? AnyShapeStyle(Tone.red.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                                    .accessibilityIdentifier("calendar.age.\(option.rawValue)")
                            }
                        }
                    }
                    if cleaner.isLoading && cleaner.events.isEmpty {
                        ProgressView("Ищу старые события…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if cleaner.events.isEmpty {
                        ContentUnavailableView(
                            "Старых событий нет",
                            systemImage: "checkmark.seal",
                            description: Text("Повторяющиеся события и дни рождения не показываются: их удаление задело бы будущие даты.")
                        )
                    } else {
                        ForEach(byYear) { group in
                            yearSection(group.year, events: group.events)
                        }
                    }
                }
                .padding(16)
            }
            if !cleaner.events.isEmpty {
                Button("Удалить (\(selection.count))") { confirmDelete = true }
                    .buttonStyle(PrimaryButtonStyle(gradient: Tone.red.gradient))
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("calendar.delete")
                    .padding(16)
                    .background(.bar)
            }
        }
        .disabled(isWorking)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar.badge.minus")
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 54, height: 54)
                .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Прошедших событий: \(cleaner.events.count)")
                    .font(.headline)
                Text("Повторяющиеся события не трогаем")
                    .font(.subheadline)
                    .opacity(0.9)
            }
            Spacer(minLength: 0)
        }
        .gradientCard(Tone.red.gradient)
    }

    private func yearSection(_ year: Int, events: [PastEvent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(year))
                    .font(.title3.bold())
                Spacer()
                let ids = Set(events.map(\.id))
                Button(ids.isSubset(of: selection) ? "Снять год" as LocalizedStringKey : "Выбрать год") {
                    if ids.isSubset(of: selection) {
                        selection.subtract(ids)
                    } else {
                        selection.formUnion(ids)
                    }
                }
                .font(.subheadline)
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(events) { event in
                    let isSelected = selection.contains(event.id)
                    Button {
                        if isSelected { selection.remove(event.id) } else { selection.insert(event.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? Tone.red.color : Color(.tertiaryLabel))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(event.swiftUIColor)
                                .frame(width: 4, height: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("\(event.start.formatted(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened)) · \(event.calendarTitle)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("calendar.event")
                    if event.id != events.last?.id {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .card(padding: 12)
        }
    }

    private func deleteSelected() {
        let ids = selection
        isWorking = true
        Task {
            do {
                try await cleaner.delete(ids, age: age)
                selection.removeAll()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

private extension PastEvent {
    var swiftUIColor: Color {
        guard color.count == 3 else { return Tone.red.color }
        return Color(.sRGB, red: color[0], green: color[1], blue: color[2])
    }
}
