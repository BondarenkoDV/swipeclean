import Photos
import SwiftUI

/// Фото и видео одного раздела памяти, самые тяжёлые первыми: отметить лишнее и отправить в корзину.
struct MediaKindView: View {
    let kind: MediaKind

    @Environment(SmartCleanAnalyzer.self) private var analyzer
    @State private var assets: [PHAsset]?
    @State private var sizes: [String: Int64] = [:]

    var body: some View {
        Group {
            if let assets {
                SelectionGridView(title: kind.title, assets: assets, analyzer: analyzer, sizes: sizes)
            } else {
                ProgressView("Считаю размеры…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(kind.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard assets == nil else { return }
        let kind = kind
        let items = await Task.detached(priority: .userInitiated) { MediaKind.assets(of: kind) }.value
        guard !Task.isCancelled else { return }
        sizes = Dictionary(items.map { ($0.asset.localIdentifier, $0.size) }, uniquingKeysWith: { first, _ in first })
        assets = items.map { $0.asset }
    }
}
