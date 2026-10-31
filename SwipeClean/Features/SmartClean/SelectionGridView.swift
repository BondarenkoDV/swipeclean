import Photos
import SwiftUI

/// Сетка с выбором для размытых фото, старых скриншотов и разделов памяти iPhone.
struct SelectionGridView: View {
    let title: LocalizedStringKey
    let assets: [PHAsset]
    let analyzer: SmartCleanAnalyzer
    /// Размеры файлов: если заданы, видны на каждой клетке.
    var sizes: [String: Int64] = [:]

    @Environment(ReviewStore.self) private var store
    @Environment(FullScreenPresenter.self) private var fullScreen
    @State private var selection: Set<String> = []
    @State private var handled: Set<String> = []

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    private var visible: [PHAsset] {
        assets.filter { !handled.contains($0.localIdentifier) }
    }

    /// Выбранные среди видимых: фото, удалённые снаружи после анализа, из выбора выпадают.
    private var selectedVisible: Set<String> {
        selection.intersection(visible.map(\.localIdentifier))
    }

    private var isAllSelected: Bool {
        !visible.isEmpty && selectedVisible.count == visible.count
    }

    var body: some View {
        Group {
            if visible.isEmpty {
                ContentUnavailableView("Пусто", systemImage: "checkmark.seal", description: Text("Здесь больше нечего разбирать."))
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(visible, id: \.localIdentifier) { asset in
                                let isSelected = selection.contains(asset.localIdentifier)
                                AssetThumbnail(asset: asset)
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Color.red)
                                            // Тень, чтобы белый кружок был виден и на светлом кадре.
                                            .shadow(color: .black.opacity(0.5), radius: 2)
                                            .padding(6)
                                    }
                                    .overlay(alignment: .bottomLeading) {
                                        if let size = sizes[asset.localIdentifier] {
                                            Text(size.formattedBytes)
                                                .font(.caption2.weight(.semibold).monospacedDigit())
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(.black.opacity(0.55), in: Capsule())
                                                .padding(5)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture { toggle(asset) }
                                    .onLongPressGesture { fullScreen.asset = asset }
                            }
                        }
                    }
                    HStack(spacing: 12) {
                        Button("Оставить (\(selectedVisible.count))") { apply(.keep) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("selection.keep")
                        Button("В корзину (\(selectedVisible.count))", role: .destructive) { apply(.trash) }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .accessibilityIdentifier("selection.trash")
                    }
                    .disabled(selectedVisible.isEmpty)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isAllSelected ? "Снять все" as LocalizedStringKey : "Выбрать все") {
                    if isAllSelected {
                        selection.removeAll()
                    } else {
                        selection = Set(visible.map(\.localIdentifier))
                    }
                }
                .disabled(visible.isEmpty)
                .accessibilityIdentifier("selection.toggleAll")
            }
        }
    }

    private func toggle(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func apply(_ decision: SwipeDecision) {
        let chosen = visible.filter { selection.contains($0.localIdentifier) }
        let ids = Set(chosen.map(\.localIdentifier))
        store.record(chosen.map { ReviewStore.Decision($0, decision) })
        handled.formUnion(ids)
        analyzer.removeHandled(ids)
        selection.removeAll()
    }
}
