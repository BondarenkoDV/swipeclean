import Photos
import SwiftUI

/// Квадратное превью ассета для сеток: у видео длительность слева внизу, размер файла, если он известен, — справа внизу.
struct AssetThumbnail: View {
    let asset: PHAsset
    var side: CGFloat = 120
    var size: Int64?

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var loadedID: String?

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
                if asset.mediaType == .video {
                    Text(asset.duration.formattedDuration)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .shadow(radius: 2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let size, size > 0 {
                    Text(size.formattedBytes)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(4)
                }
            }
            .clipped()
            .task(id: asset.localIdentifier) {
                // Повторное появление в сетке не перезапрашивает уже показанное превью.
                guard loadedID != asset.localIdentifier else { return }
                let loaded = await AssetImageLoader.shared.image(
                    for: asset,
                    targetSize: CGSize(width: side * displayScale, height: side * displayScale)
                )
                guard !Task.isCancelled else { return }
                image = loaded
                loadedID = loaded == nil ? nil : asset.localIdentifier
            }
    }
}
