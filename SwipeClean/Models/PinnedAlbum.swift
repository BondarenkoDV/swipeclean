import Foundation
import SwiftData

/// Альбом, закреплённый на панели под карточкой.
@Model
final class PinnedAlbum {
    @Attribute(.unique) var collectionID: String
    var title: String
    var order: Int

    init(collectionID: String, title: String, order: Int) {
        self.collectionID = collectionID
        self.title = title
        self.order = order
    }
}

extension PinnedAlbum {
    /// Убирает с панели альбомы, удалённые в приложении «Фото», и подтягивает новые названия переименованных.
    /// Удалённый альбом иначе висел бы на панели вечно: в списке выбора его уже нет, и открепить его было нечем.
    /// При ограниченном доступе альбомы могут быть просто не видны, поэтому тогда ничего не удаляется.
    @MainActor
    static func sync(in context: ModelContext, removeMissing: Bool) async {
        let ids = ((try? context.fetch(FetchDescriptor<PinnedAlbum>())) ?? []).map(\.collectionID)
        guard !ids.isEmpty else { return }
        let titles = await Task.detached(priority: .utility) { LibraryEditor.albumTitles(ids) }.value
        // Пока шёл запрос, альбомы могли открепить: работаем с тем, что лежит в хранилище сейчас.
        var changed = false
        for album in (try? context.fetch(FetchDescriptor<PinnedAlbum>())) ?? [] where ids.contains(album.collectionID) {
            if let title = titles[album.collectionID] {
                if album.title != title {
                    album.title = title
                    changed = true
                }
            } else if removeMissing {
                context.delete(album)
                changed = true
            }
        }
        if changed { try? context.save() }
    }
}
