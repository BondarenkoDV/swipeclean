import Photos
import SwiftUI

/// Квадратное превью ассета для сеток.
struct AssetThumbnail: View {
    let asset: PHAsset
    var side: CGFloat = 120

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
