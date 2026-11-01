import Photos
import SwiftData
import SwiftUI

/// Загружает подборку, убирает уже разобранное и открывает стопку карточек.
struct SourceDeckView: View {
    let source: LibrarySource

    @Environment(ReviewStore.self) private var store
    @Environment(PhotoLibraryService.self) private var library
    @Environment(ProtectedStore.self) private var protection
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKeys.hapticsEnabled) private var hapticsEnabled = true
    @State private var assets: [PHAsset]?
    /// В подборке вообще нет фото (а не всё уже разобрано).
    @State private var isSourceEmpty = false
    /// Решение, которое было у фото до свайпа: при отмене его нужно вернуть.
    @State private var previousDecisions: [String: SwipeDecision] = [:]
    /// Последняя правка медиатеки. Следующая ждёт её: иначе быстрое «в избранное» и отмена
    /// могли выполниться в обратном порядке, и фото осталось бы в избранном.
    @State private var lastEdit: Task<Void, Never>?
    @State private var missingAlbumTitle: String?
    /// Похвала за первую чистку дня: сколько дней подряд теперь в серии.
    @State private var streakToast: Int?
    @State private var streakToastTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let assets {
                if assets.isEmpty, isSourceEmpty {
                    ContentUnavailableView(
                        "Здесь пусто",
                        systemImage: "photo.on.rectangle",
                        description: Text("В подборке «\(source.title)» нет фото.")
                    )
                } else if assets.isEmpty {
                    ContentUnavailableView(
                        "Всё разобрано",
                        systemImage: "checkmark.seal",
                        description: Text("В подборке «\(source.title)» не осталось неразобранных фото.")
                    )
                } else {
                    SwipeDeckView(
                        title: source.title,
                        assets: assets,
                        onDecision: apply,
                        onUndo: revert
                    )
                }
            } else {
                ProgressView(source == .largeFiles ? "Считаю размеры файлов…" as LocalizedStringKey : "Загрузка…")
            }
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let streakToast {
                StreakToast(days: streakToast)
                    .padding(.top, 52)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sensoryFeedback(.success, trigger: streakToast) { _, new in hapticsEnabled && new != nil }
        .task { await load() }
        .task { await PinnedAlbum.sync(in: context, removeMissing: !library.isLimited) }
        .alert(
            "Альбома больше нет",
            isPresented: Binding(get: { missingAlbumTitle != nil }, set: { if !$0 { missingAlbumTitle = nil } })
        ) {
            Button("OK") { missingAlbumTitle = nil }
        } message: {
            Text("Альбом «\(missingAlbumTitle ?? "")» удалён в приложении «Фото», поэтому фото только оставлено. Альбом убран с панели.")
        }
    }

    private func apply(_ action: SwipeDeckViewModel.Action) {
        let id = action.asset.localIdentifier
        previousDecisions[id] = store.item(for: id)?.decision
        let cleanedBefore = store.isActiveToday
        store.record(action.asset, decision: action.decision)
        if !cleanedBefore, store.isActiveToday { celebrateStreak() }
        enqueueEdit {
            if action.decision == .favorite {
                try? await LibraryEditor.setFavorite(action.asset, true)
            }
            if let album = action.albumID {
                do {
                    try await LibraryEditor.add(action.asset, toAlbum: album)
                } catch LibraryEditor.EditError.albumMissing {
                    missingAlbumTitle = albumTitle(album)
                    await PinnedAlbum.sync(in: context, removeMissing: !library.isLimited)
                } catch {}
            }
        }
    }

    private func revert(_ action: SwipeDeckViewModel.Action) {
        let id = action.asset.localIdentifier
        store.undo(action.asset, restoring: previousDecisions.removeValue(forKey: id))
        enqueueEdit {
            // PHAsset — снимок до изменения, поэтому isFavorite здесь исходное значение.
            if action.decision == .favorite && !action.asset.isFavorite {
                try? await LibraryEditor.setFavorite(action.asset, false)
            }
            if let album = action.albumID {
                try? await LibraryEditor.remove(action.asset, fromAlbum: album)
            }
        }
    }

    private func celebrateStreak() {
        let days = store.streak().current
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { streakToast = days }
        streakToastTask?.cancel()
        streakToastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { streakToast = nil }
        }
    }

    private func enqueueEdit(_ edit: @escaping @MainActor () async -> Void) {
        let previous = lastEdit
        lastEdit = Task {
            await previous?.value
            await edit()
        }
    }

    private func albumTitle(_ id: String) -> String {
        let descriptor = FetchDescriptor<PinnedAlbum>(predicate: #Predicate { $0.collectionID == id })
        return (try? context.fetch(descriptor).first?.title) ?? ""
    }

    private func load() async {
        guard assets == nil else { return }
        let source = source
        let reviewed = store.reviewedIDs
        // Защищённые фото («Не трогать» и избранное, если включено) в разбор не попадают.
        let policy = protection.policy
        if source == .later {
            let ids = store.laterIDs()
            let later = await Task.detached { LibraryFetcher.fetch(ids: ids) }.value
            assets = later.filter { !policy.protects($0) }
            return
        }
        let all = await Task.detached(priority: .userInitiated) { LibraryFetcher.fetch(source) }.value
        isSourceEmpty = all.isEmpty
        assets = all.filter { !reviewed.contains($0.localIdentifier) && !policy.protects($0) }
    }
}
