import SwiftData
import SwiftUI

/// Выбор альбомов для панели под карточкой и создание нового альбома.
struct AlbumPickerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(PhotoLibraryService.self) private var library
    @Query(sort: \PinnedAlbum.order) private var pinned: [PinnedAlbum]

    @State private var albums: [AlbumInfo] = []
    @State private var newTitle = ""
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(albums) { album in
                        Button {
                            toggle(album)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(album.title).foregroundStyle(.primary)
                                    Text("\(album.count) объектов").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isPinned(album) {
                                    Image(systemName: "pin.fill").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Закреплённые альбомы появятся под карточкой. Тап по альбому кладёт фото туда и переходит к следующему.")
                }
            }
            .navigationTitle("Альбомы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Новый", systemImage: "plus") { showCreate = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .alert("Новый альбом", isPresented: $showCreate) {
                TextField("Название", text: $newTitle)
                Button("Отмена", role: .cancel) { newTitle = "" }
                Button("Создать") { Task { await create() } }
                    .accessibilityIdentifier("albums.create")
            }
            .task { await loadAlbums() }
        }
    }

    private func isPinned(_ album: AlbumInfo) -> Bool {
        pinned.contains { $0.collectionID == album.id }
    }

    private func toggle(_ album: AlbumInfo) {
        if let existing = pinned.first(where: { $0.collectionID == album.id }) {
            context.delete(existing)
        } else {
            context.insert(PinnedAlbum(collectionID: album.id, title: album.title, order: (pinned.map(\.order).max() ?? -1) + 1))
        }
        try? context.save()
    }

    /// Подсчёт объектов в каждом альбоме обращается к медиатеке, на главном потоке это заметно.
    private func loadAlbums() async {
        albums = await Task.detached(priority: .userInitiated) { LibraryEditor.userAlbums() }.value
        await PinnedAlbum.sync(in: context, removeMissing: !library.isLimited)
    }

    private func create() async {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        newTitle = ""
        guard !title.isEmpty, let id = try? await LibraryEditor.createAlbum(title: title) else { return }
        await loadAlbums()
        if let album = albums.first(where: { $0.id == id }) {
            toggle(album)
        }
    }
}
