import SwiftData
import SwiftUI

/// Горизонтальная панель закреплённых альбомов: тап кладёт текущее фото в альбом.
struct PinnedAlbumsBar: View {
    @Query(sort: \PinnedAlbum.order) private var albums: [PinnedAlbum]

    let onSelect: (String) -> Void
    let onManage: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(albums) { album in
                    Button {
                        onSelect(album.collectionID)
                    } label: {
                        Label(album.title, systemImage: "rectangle.stack.badge.plus")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onManage) {
                    Label(albums.isEmpty ? "Альбомы" as LocalizedStringKey : "Изменить", systemImage: albums.isEmpty ? "plus" : "slider.horizontal.3")
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 40)
    }
}
