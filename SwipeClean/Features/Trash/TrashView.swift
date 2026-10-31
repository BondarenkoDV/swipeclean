import Photos
import SwiftUI

/// Корзина: всё, что отправлено свайпом влево. Удаление из медиатеки — одним подтверждением iOS.
struct TrashView: View {
    @Environment(ReviewStore.self) private var store
    @Environment(PhotoLibraryService.self) private var library
    @Environment(FullScreenPresenter.self) private var fullScreen
    @State private var entries: [TrashEntry] = []
    @State private var selection: Set<String> = []
    @State private var isSelecting = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var lastFreed: Int64?
    @State private var isVisible = false
    @State private var reloadTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    private var totalBytes: Int64 { entries.reduce(0) { $0 + $1.fileSize } }
    private var targetIDs: Set<String> {
        isSelecting && !selection.isEmpty ? selection : Set(entries.map(\.id))
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("Корзина пуста", systemImage: "trash")
                    } description: {
                        if let lastFreed {
                            Text("Освобождено \(ByteCountFormatter.string(fromByteCount: lastFreed, countStyle: .file)). Фото ещё 30 дней лежат в «Недавно удалённых» приложения Фото.")
                        } else {
                            Text("Свайпните фото влево, и оно попадёт сюда.")
                        }
                    }
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .screenBackground()
            .navigationTitle("Корзина")
            .toolbar { toolbar }
            .alert("Не удалось удалить", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onAppear {
            isVisible = true
            reload()
        }
        .onDisappear { isVisible = false }
        .onChange(of: store.trashCount) { _, _ in
            // Пока вкладка не видна, перечитывать корзину на каждый свайп незачем.
            if isVisible { reload() }
        }
        .onChange(of: library.changeCount) { _, _ in
            if isVisible { reload() }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                summary
                    .padding(16)
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(entries) { entry in
                        AssetThumbnail(asset: entry.asset)
                            .overlay(alignment: .topTrailing) {
                                if isSelecting {
                                    Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Color.accentColor)
                                        .padding(6)
                                }
                            }
                            .contentShape(Rectangle())
                            // Без режима выбора тап открывает фото: перед удалением его можно рассмотреть.
                            .onTapGesture {
                                if isSelecting {
                                    toggle(entry.id)
                                } else {
                                    fullScreen.asset = entry.asset
                                }
                            }
                            .contextMenu {
                                Button("Вернуть", systemImage: "arrow.uturn.backward") {
                                    lastFreed = nil
                                    store.restore([entry.id])
                                }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(isSelecting && selection.contains(entry.id) ? "Выбрано" : "Фото")
                            .accessibilityIdentifier("trash.item")
                    }
                }
                Text("Удалённые фото 30 дней хранятся в альбоме «Недавно удалённые» приложения Фото, их можно восстановить оттуда.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
            }
            actions
        }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            Image(systemName: "trash.fill")
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 54, height: 54)
                .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(entries.count) объектов")
                    .font(.headline)
                Text("Освободится \(totalBytes.formattedBytes)")
                    .font(.subheadline)
                    .opacity(0.9)
            }
            Spacer(minLength: 0)
        }
        .gradientCard(Tone.red.gradient)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                // Иначе пустая после возврата корзина показывала бы «Освобождено» от прошлого удаления.
                lastFreed = nil
                store.restore(targetIDs)
                selection.removeAll()
            } label: {
                Text(isSelecting && !selection.isEmpty ? "Вернуть (\(selection.count))" as LocalizedStringKey : "Вернуть всё")
            }
            .buttonStyle(TintedButtonStyle(tint: Tone.green.color))
            .accessibilityIdentifier("trash.restore")

            Button(role: .destructive) {
                Task { await delete() }
            } label: {
                Group {
                    if isDeleting {
                        ProgressView().tint(.white)
                    } else {
                        Text(isSelecting && !selection.isEmpty ? "Удалить (\(selection.count))" as LocalizedStringKey : "Удалить всё")
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle(gradient: Tone.red.gradient))
            .accessibilityIdentifier("trash.delete")
        }
        .disabled(isDeleting)
        .padding()
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !entries.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "Готово" as LocalizedStringKey : "Выбрать") {
                    isSelecting.toggle()
                    selection.removeAll()
                }
            }
        }
    }

    private func toggle(_ id: String) {
        guard isSelecting else { return }
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            lastFreed = try await store.deleteFromLibrary(targetIDs)
            selection.removeAll()
            isSelecting = false
        } catch {
            // Отмена в системном диалоге тоже приходит ошибкой — её не показываем.
            // В разных версиях iOS она приходит из PhotoKit или как общая ошибка Cocoa с тем же кодом 3072.
            let nsError = error as NSError
            let isCancel = nsError.code == PHPhotosError.userCancelled.rawValue
                && (nsError.domain == "PHPhotosErrorDomain" || nsError.domain == NSCocoaErrorDomain)
            if !isCancel {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reload() {
        let items = store.trashItems()
        let ids = items.map(\.localIdentifier)
        let sizes = Dictionary(items.map { ($0.localIdentifier, $0.fileSize) }, uniquingKeysWith: { first, _ in first })
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            // Запрос к медиатеке идёт в фоне: корзина на тысячи фото не должна держать главный поток.
            let byID = await Task.detached(priority: .userInitiated) { LibraryFetcher.assetsByID(ids) }.value
            guard !Task.isCancelled else { return }
            entries = ids.compactMap { id in
                byID[id].map { TrashEntry(asset: $0, fileSize: sizes[id] ?? 0) }
            }
            selection.formIntersection(Set(entries.map(\.id)))
            // При ограниченном доступе «не найдено» значит «не выбрано пользователем», а не «удалено»:
            // такие записи не трогаем, иначе корзина теряла бы решения.
            let missing = Set(ids).subtracting(byID.keys)
            if !missing.isEmpty, !library.isLimited {
                store.forgetMissing(missing)
            }
        }
    }
}

private struct TrashEntry: Identifiable {
    let asset: PHAsset
    let fileSize: Int64
    var id: String { asset.localIdentifier }
}
