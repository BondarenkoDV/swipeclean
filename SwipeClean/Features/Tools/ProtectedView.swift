import Photos
import SwiftUI

/// «Не трогать»: фото и видео, которые приложение никогда не предложит удалить. Их нет в свайп-разборе,
/// умной чистке, разделах памяти и сжатии, а из корзины приложения они возвращаются.
struct ProtectedView: View {
    @Environment(ProtectedStore.self) private var protection
    @Environment(ReviewStore.self) private var store
    @Environment(PhotoLibraryService.self) private var library
    @Environment(FullScreenPresenter.self) private var fullScreen
    @State private var assets: [PHAsset] = []
    @State private var favoritesCount: Int?
    @State private var isLoading = true
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var isPicking = false

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                favoritesCard
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else if assets.isEmpty {
                    emptyCard
                }
            }
            .padding(16)
            if !assets.isEmpty {
                grid
            }
        }
        .screenBackground()
        .navigationTitle("Не трогать")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                removeBar
            }
        }
        .sheet(isPresented: $isPicking) {
            ProtectedPickerView(excluded: protection.ids) { ids in
                protection.protect(ids, store: store)
            }
        }
        .task(id: protection.ids) { await load() }
        .onChange(of: library.changeCount) { _, _ in Task { await load() } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 54, height: 54)
                .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("В списке: \(protection.count)")
                    .font(.headline)
                    .accessibilityIdentifier("protected.count")
                Text("Эти фото и видео не попадут в разбор, умную чистку, разделы памяти и сжатие, а удаление их пропустит.")
                    .font(.subheadline)
                    .opacity(0.9)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .gradientCard(Tone.teal.gradient)
    }

    private var favoritesCard: some View {
        Toggle(isOn: Binding(
            get: { protection.protectsFavorites },
            set: { protection.setProtectsFavorites($0) }
        )) {
            HStack(spacing: 12) {
                ToneIcon(symbol: "heart.fill", tone: .pink, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Избранное тоже не трогать")
                        .font(.headline)
                    Text(favoritesSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(Tone.teal.color)
        .card(padding: 14)
        .accessibilityIdentifier("protected.favorites")
    }

    private var favoritesSubtitle: LocalizedStringKey {
        guard let favoritesCount else { return "Всё, что отмечено сердечком в «Фото»" }
        return "Сейчас в избранном: \(favoritesCount)"
    }

    private var emptyCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.largeTitle)
                .foregroundStyle(Tone.teal.color)
            Text("Список пуст")
                .font(.headline)
            Text("Добавьте фото и видео, которые жалко потерять. Ещё фото можно защитить кнопкой «Не трогать», открыв его на весь экран.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Добавить фото") { isPicking = true }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("protected.addFirst")
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(assets, id: \.localIdentifier) { asset in
                let id = asset.localIdentifier
                let isSelected = selection.contains(id)
                AssetThumbnail(asset: asset)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: isSelecting ? (isSelected ? "checkmark.circle.fill" : "circle") : "lock.shield.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isSelecting ? Color.accentColor : Tone.teal.color)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .padding(6)
                    }
                    .contentShape(Rectangle())
                    // Без режима выбора тап открывает фото: там же защиту можно снять.
                    .onTapGesture {
                        if isSelecting {
                            toggle(id)
                        } else {
                            fullScreen.asset = asset
                        }
                    }
                    .contextMenu {
                        Button("Снять защиту", systemImage: "lock.open") {
                            protection.remove([id])
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(isSelecting && isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityLabel(asset.mediaType == .video ? Text("Видео") : Text("Фото"))
                    .accessibilityValue(isSelecting && isSelected ? Text("Выбрано") : Text(verbatim: ""))
                    .accessibilityIdentifier("protected.item")
            }
        }
    }

    private var removeBar: some View {
        Button(role: .destructive) {
            protection.remove(selection)
            selection.removeAll()
            isSelecting = false
        } label: {
            Text("Снять защиту (\(selection.count))")
        }
        .buttonStyle(PrimaryButtonStyle(gradient: Tone.orange.gradient))
        .disabled(selection.isEmpty)
        .accessibilityIdentifier("protected.remove")
        .padding()
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !assets.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "Готово" as LocalizedStringKey : "Выбрать") {
                    isSelecting.toggle()
                    selection.removeAll()
                }
                .accessibilityIdentifier("protected.select")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isPicking = true
            } label: {
                Label("Добавить", systemImage: "plus")
            }
            .disabled(isSelecting)
            .accessibilityIdentifier("protected.add")
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func load() async {
        let ids = Array(protection.ids)
        let (fetched, favorites) = await Task.detached(priority: .userInitiated) {
            (LibraryFetcher.fetch(ids: ids), ProtectionPolicy.favoriteIDs().count)
        }.value
        guard !Task.isCancelled else { return }
        assets = fetched
        favoritesCount = favorites
        selection.formIntersection(Set(fetched.map(\.localIdentifier)))
        if fetched.isEmpty { isSelecting = false }
        isLoading = false
        // Фото удалили в «Фото» или другом приложении: держать его в списке незачем. При ограниченном доступе
        // «не найдено» значит «не выбрано пользователем», а не «удалено», поэтому тогда список не трогаем.
        let missing = Set(ids).subtracting(fetched.map(\.localIdentifier))
        if !missing.isEmpty, !library.isLimited {
            protection.remove(missing)
        }
    }
}

/// Выбор фото и видео из медиатеки для списка «Не трогать». Уже защищённые не показываются.
private struct ProtectedPickerView: View {
    let excluded: Set<String>
    let onPick: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var assets: [PHAsset] = []
    @State private var selection: Set<String> = []
    @State private var isLoading = true

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if assets.isEmpty {
                    ContentUnavailableView("Нечего добавить", systemImage: "lock.shield", description: Text("Все фото уже в списке «Не трогать»."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(assets, id: \.localIdentifier) { asset in
                                let isSelected = selection.contains(asset.localIdentifier)
                                AssetThumbnail(asset: asset)
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Tone.teal.color)
                                            .shadow(color: .black.opacity(0.5), radius: 2)
                                            .padding(6)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if isSelected {
                                            selection.remove(asset.localIdentifier)
                                        } else {
                                            selection.insert(asset.localIdentifier)
                                        }
                                    }
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                                    .accessibilityLabel(isSelected ? "Выбрано" : "Не выбрано")
                                    .accessibilityIdentifier("protectedPicker.item")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Что не трогать")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить (\(selection.count))") {
                        // Порядок как в сетке: так список не зависит от порядка нажатий.
                        let picked = assets.map(\.localIdentifier).filter { selection.contains($0) }
                        dismiss()
                        onPick(picked)
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("protectedPicker.add")
                }
            }
        }
        .task {
            let excluded = excluded
            let all = await Task.detached(priority: .userInitiated) { LibraryFetcher.fetch(.all) }.value
            assets = all.filter { !excluded.contains($0.localIdentifier) }
            isLoading = false
        }
    }
}
