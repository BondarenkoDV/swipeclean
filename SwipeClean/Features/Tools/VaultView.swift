import AVKit
import Photos
import SwiftUI

/// Секретная папка: PIN-код при первом входе, затем сетка спрятанных фото и видео.
/// Папка закрывается, когда с экрана уходят или приложение уходит в фон.
struct VaultView: View {
    @Environment(VaultStore.self) private var vault
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKeys.vaultBiometrics) private var useBiometrics = true

    /// Первый ввод нового PIN-кода; второй должен с ним совпасть.
    @State private var firstEntry: String?
    @State private var setupMismatch = false
    @State private var isPicking = false
    @State private var isImporting = false
    @State private var pendingOriginals: [String] = []
    @State private var selection: Set<UUID> = []
    @State private var isSelecting = false
    @State private var opened: VaultItem?
    @State private var confirmErase = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]

    var body: some View {
        Group {
            if !vault.hasPasscode {
                setup
            } else if !vault.isUnlocked {
                unlock
            } else {
                content
            }
        }
        // Экран PIN-кода по ширине равен клавиатуре: без растяжки фон лёг бы узкой полосой посередине,
        // а по бокам просвечивал бы предыдущий экран.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
        .navigationTitle("Секретная папка")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        // Содержимое прячется и в переключателе приложений, и под системными окнами.
        .overlay {
            if vault.isUnlocked && scenePhase != .active {
                Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            }
        }
        .onDisappear { vault.lock() }
        .task {
            if vault.hasPasscode, !vault.isUnlocked, useBiometrics {
                _ = await vault.unlockWithBiometrics()
            }
        }
        .sheet(isPresented: $isPicking) {
            VaultPickerView { assets in
                Task { await importAssets(assets) }
            }
        }
        .sheet(item: $opened) { item in
            VaultItemView(item: item)
        }
        .confirmationDialog("Удалить оригиналы из «Фото»?", isPresented: Binding(
            get: { !pendingOriginals.isEmpty },
            set: { if !$0 { pendingOriginals = [] } }
        ), titleVisibility: .visible) {
            Button("Удалить из «Фото»", role: .destructive) {
                let ids = pendingOriginals
                pendingOriginals = []
                Task { try? await LibraryEditor.deleteAssets(withIDs: ids) }
            }
            .accessibilityIdentifier("vault.deleteOriginals")
            Button("Оставить в «Фото»", role: .cancel) { pendingOriginals = [] }
        } message: {
            Text("Копии уже в секретной папке. Пока оригиналы в «Фото», их видно в галерее.")
        }
        .confirmationDialog("Сбросить секретную папку?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Удалить всё и сбросить PIN-код", role: .destructive) { vault.erase() }
        } message: {
            Text("Все файлы в папке будут удалены без возможности восстановления.")
        }
        .confirmationDialog("Удалить выбранное навсегда?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                vault.delete(vault.items.filter { selection.contains($0.id) })
                selection.removeAll()
                isSelecting = false
            }
            .accessibilityIdentifier("vault.confirmDelete")
        } message: {
            Text("Файлы из секретной папки не попадают в «Недавно удалённые».")
        }
        .alert("Не получилось", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - PIN-код

    private var setup: some View {
        PasscodeView(
            title: firstEntry == nil ? "Придумайте PIN-код" : "Повторите PIN-код",
            subtitle: setupMismatch
                ? "Коды не совпали, попробуйте ещё раз."
                : "4 цифры. Без него папку не открыть, а восстановить его нельзя."
        ) { code in
            guard let first = firstEntry else {
                firstEntry = code
                setupMismatch = false
                return true
            }
            firstEntry = nil
            guard first == code else {
                setupMismatch = true
                return false
            }
            vault.setPasscode(code)
            return true
        }
        .id(firstEntry == nil)
    }

    private var unlock: some View {
        // Раз в секунду: обратный отсчёт паузы после неверных попыток.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = vault.lockedUntil.map { $0.timeIntervalSince(context.date) } ?? 0
            VStack(spacing: 0) {
                PasscodeView(
                    title: "Введите PIN-код",
                    subtitle: remaining > 0 ? "Слишком много неверных попыток. Повторите через \(Self.countdown(remaining))" : nil,
                    biometryType: useBiometrics ? vault.biometryType : .none,
                    onBiometrics: { Task { _ = await vault.unlockWithBiometrics() } },
                    isLocked: remaining > 0
                ) { code in
                    vault.unlock(with: code)
                }
                Button("Забыли PIN-код?") { confirmErase = true }
                    .font(.footnote)
                    .padding(.bottom, 12)
            }
        }
    }

    private static func countdown(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded(.up)).formatted(.time(pattern: .minuteSecond))
    }

    // MARK: - Содержимое

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    if vault.items.isEmpty {
                        ContentUnavailableView(
                            "Папка пуста",
                            systemImage: "lock.square.stack",
                            description: Text("Добавьте фото и видео из медиатеки. Их можно вернуть в «Фото» в любой момент.")
                        )
                        .padding(.top, 20)
                    } else {
                        grid
                    }
                }
                .padding(16)
            }
            if isSelecting {
                selectionBar
            } else {
                Button {
                    isPicking = true
                } label: {
                    Label(isImporting ? "Копирую…" as LocalizedStringKey : "Добавить из «Фото»", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle(gradient: Tone.indigo.gradient))
                .disabled(isImporting)
                .accessibilityIdentifier("vault.add")
                .padding(16)
                .background(.bar)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 28, weight: .semibold))
                .frame(width: 54, height: 54)
                .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Файлов: \(vault.items.count) · \(vault.totalSize.formattedBytes)")
                    .font(.headline)
                Text("Хранятся только на этом iPhone и не попадают в iCloud.")
                    .font(.caption)
                    .opacity(0.9)
            }
            Spacer(minLength: 0)
        }
        .gradientCard(Tone.indigo.gradient)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(vault.items) { item in
                VaultThumbnail(item: item, url: vault.url(for: item))
                    .overlay(alignment: .topTrailing) {
                        if isSelecting {
                            Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Tone.indigo.color)
                                .shadow(color: .black.opacity(0.5), radius: 2)
                                .padding(6)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSelecting {
                            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                        } else {
                            opened = item
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(item.isVideo ? "Видео" : "Фото")
                    .accessibilityIdentifier("vault.item")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button("Вернуть в «Фото» (\(selection.count))") {
                let items = vault.items.filter { selection.contains($0.id) }
                Task {
                    do {
                        try await vault.restoreToLibrary(items)
                        selection.removeAll()
                        isSelecting = false
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .buttonStyle(TintedButtonStyle(tint: Tone.indigo.color))
            .accessibilityIdentifier("vault.restore")
            Button("Удалить (\(selection.count))") { confirmDelete = true }
                .buttonStyle(PrimaryButtonStyle(gradient: Tone.red.gradient))
                .accessibilityIdentifier("vault.delete")
        }
        .disabled(selection.isEmpty)
        .padding(16)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if vault.isUnlocked {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !vault.items.isEmpty {
                        Button(isSelecting ? "Готово" as LocalizedStringKey : "Выбрать", systemImage: "checkmark.circle") {
                            isSelecting.toggle()
                            selection.removeAll()
                        }
                    }
                    if vault.biometryType != .none {
                        Toggle(vault.biometryType == .touchID ? "Вход по Touch ID" as LocalizedStringKey : "Вход по Face ID", isOn: $useBiometrics)
                    }
                    Button("Закрыть папку", systemImage: "lock") { vault.lock() }
                    Button("Сбросить папку", systemImage: "trash", role: .destructive) { confirmErase = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Ещё")
                .accessibilityIdentifier("vault.menu")
            }
        }
    }

    private func importAssets(_ assets: [PHAsset]) async {
        guard !assets.isEmpty else { return }
        isImporting = true
        let imported = await vault.importAssets(assets)
        isImporting = false
        if imported.count < assets.count {
            errorMessage = String(localized: "Не удалось скопировать: \(assets.count - imported.count). Проверьте интернет, если оригиналы в iCloud.")
        }
        pendingOriginals = imported
    }
}

/// Превью файла из секретной папки. Картинки читаются вне главного потока и кэшируются в памяти.
private struct VaultThumbnail: View {
    let item: VaultItem
    let url: URL

    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.isVideo {
                    Image(systemName: "video.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .clipped()
            .task(id: item.id) {
                image = await VaultThumbnails.shared.image(for: item, url: url)?.value
            }
    }
}

/// Кэш превью секретной папки. Живёт только в памяти: на диск превью не пишутся, чтобы не оставлять следов.
actor VaultThumbnails {
    static let shared = VaultThumbnails()
    private var cache: [UUID: Handoff<UIImage>] = [:]

    func image(for item: VaultItem, url: URL) async -> Handoff<UIImage>? {
        if let cached = cache[item.id] { return cached }
        let image: UIImage?
        if item.isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            image = (try? await generator.image(at: .zero).image).map(UIImage.init(cgImage:))
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
            ]
            image = CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
                .map(UIImage.init(cgImage:))
        }
        guard let image else { return nil }
        let handoff = Handoff(value: image)
        cache[item.id] = handoff
        return handoff
    }
}

/// Просмотр файла из секретной папки: фото целиком или видео с плеером.
private struct VaultItemView: View {
    let item: VaultItem

    @Environment(VaultStore.self) private var vault
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                        .accessibilityIdentifier("vault.closeItem")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Вернуть в «Фото»", systemImage: "square.and.arrow.up") {
                        Task {
                            do {
                                try await vault.restoreToLibrary([item])
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    Spacer()
                    Button("Удалить", systemImage: "trash", role: .destructive) {
                        vault.delete([item])
                        dismiss()
                    }
                }
            }
            .toolbarBackground(.visible, for: .bottomBar)
            .alert("Не получилось", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .task {
            let url = vault.url(for: item)
            if item.isVideo {
                let player = AVPlayer(url: url)
                self.player = player
                player.play()
            } else {
                image = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path).map(Handoff.init) }.value?.value
            }
        }
        .onDisappear { player?.pause() }
    }
}

/// Выбор фото и видео из медиатеки для секретной папки.
private struct VaultPickerView: View {
    let onPick: ([PHAsset]) -> Void

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
                                            .foregroundStyle(.white, Tone.indigo.color)
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
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityLabel(isSelected ? "Выбрано" : "Не выбрано")
                                    .accessibilityIdentifier("vaultPicker.item")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Выберите фото")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить (\(selection.count))") {
                        let picked = assets.filter { selection.contains($0.localIdentifier) }
                        dismiss()
                        onPick(picked)
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("vaultPicker.add")
                }
            }
        }
        .task {
            assets = await Task.detached(priority: .userInitiated) { LibraryFetcher.fetch(.all) }.value
            isLoading = false
        }
    }
}
