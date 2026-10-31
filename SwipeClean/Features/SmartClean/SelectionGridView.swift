import Photos
import SwiftUI

/// Сетка с выбором для размытых фото, старых скриншотов, тяжёлых видео и разделов памяти iPhone.
/// Если известны размеры файлов, они видны справа внизу на каждой клетке, а сетку можно сортировать.
struct SelectionGridView: View {
    let title: LocalizedStringKey
    let assets: [PHAsset]
    let analyzer: SmartCleanAnalyzer
    /// Размеры файлов: если заданы, видны на каждой клетке.
    var sizes: [String: Int64] = [:]
    /// Посчитать размеры самой, если их не передали (тяжёлые видео умной чистки).
    var measuresSizes = false

    @Environment(ReviewStore.self) private var store
    @Environment(FullScreenPresenter.self) private var fullScreen
    @AppStorage(SettingsKeys.mediaSortOrder) private var sortOrder = MediaSortOrder.largest
    @State private var selection: Set<String> = []
    @State private var handled: Set<String> = []
    @State private var measuredSizes: [String: Int64] = [:]
    /// Ассеты в выбранном порядке. Сортируются при смене порядка, а не на каждое нажатие по клетке.
    @State private var ordered: [PHAsset]?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    private var knownSizes: [String: Int64] {
        sizes.isEmpty ? measuredSizes : sizes
    }

    private var isSortable: Bool {
        !sizes.isEmpty || measuresSizes
    }

    private var visible: [PHAsset] {
        (ordered ?? assets).filter { !handled.contains($0.localIdentifier) }
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
                                let size = knownSizes[asset.localIdentifier]
                                AssetThumbnail(asset: asset, size: size)
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Color.red)
                                            // Тень, чтобы белый кружок был виден и на светлом кадре.
                                            .shadow(color: .black.opacity(0.5), radius: 2)
                                            .padding(6)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture { toggle(asset) }
                                    .onLongPressGesture { fullScreen.asset = asset }
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                                    .accessibilityLabel(asset.mediaType == .video ? Text("Видео \(asset.duration.formattedDuration)") : Text("Фото"))
                                    .accessibilityValue(size.map { Text($0.formattedBytes) } ?? Text(verbatim: ""))
                                    .accessibilityAction(named: "Открыть") { fullScreen.asset = asset }
                                    .accessibilityIdentifier("selection.item")
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
            if isSortable {
                ToolbarItem(placement: .topBarTrailing) {
                    MediaSortMenu(order: $sortOrder)
                        .disabled(visible.isEmpty)
                        .accessibilityIdentifier("selection.sort")
                }
            }
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
        .onAppear(perform: reorder)
        .onChange(of: sortOrder) { _, _ in reorder() }
        .onChange(of: assets.map(\.localIdentifier)) { _, _ in reorder() }
        .task { await measureSizes() }
    }

    private func reorder() {
        guard isSortable else {
            ordered = nil
            return
        }
        let sizes = knownSizes
        ordered = sortOrder.sorted(assets) { asset in
            MediaSortOrder.Key(id: asset.localIdentifier, size: sizes[asset.localIdentifier] ?? 0, date: asset.creationDate)
        }
    }

    /// Размеры берутся из кэша, первый раз считаются вне главного потока.
    private func measureSizes() async {
        guard measuresSizes, sizes.isEmpty, measuredSizes.isEmpty, !assets.isEmpty else { return }
        let assets = assets
        let measured = await Task.detached(priority: .userInitiated) {
            let sizes = Dictionary(assets.map { ($0.localIdentifier, $0.cachedTotalSize) }, uniquingKeysWith: { first, _ in first })
            FileSizeCache.shared.save()
            return sizes
        }.value
        guard !Task.isCancelled else { return }
        measuredSizes = measured
        reorder()
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
