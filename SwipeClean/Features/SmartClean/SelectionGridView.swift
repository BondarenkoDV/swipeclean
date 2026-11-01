import Photos
import SwiftUI

/// Сетка с выбором для размытых фото, старых скриншотов, тяжёлых видео и разделов памяти iPhone.
/// Если известны размеры файлов, они видны справа внизу на каждой клетке, а сетку можно сортировать.
struct SelectionGridView<Header: View>: View {
    let title: LocalizedStringKey
    let assets: [PHAsset]
    let analyzer: SmartCleanAnalyzer
    /// Размеры файлов: если заданы, видны на каждой клетке.
    var sizes: [String: Int64] = [:]
    /// Посчитать размеры самой, если их не передали (тяжёлые видео умной чистки).
    var measuresSizes = false
    /// Какие фото только что оставлены или отправлены в корзину: экран раздела памяти пересчитывает по ним сводку.
    var onHandled: @MainActor (Set<String>) -> Void = { _ in }
    /// Над сеткой, листается вместе с ней.
    let header: Header

    @Environment(ReviewStore.self) private var store
    @Environment(FullScreenPresenter.self) private var fullScreen
    @Environment(ProtectedStore.self) private var protection
    @AppStorage(SettingsKeys.mediaSortOrder) private var sortOrder = MediaSortOrder.largest
    @State private var selection: Set<String> = []
    @State private var handled: Set<String> = []
    @State private var measuredSizes: [String: Int64] = [:]
    /// Ассеты в выбранном порядке. Сортируются при смене порядка, а не на каждое нажатие по клетке.
    @State private var ordered: [PHAsset]?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    init(
        title: LocalizedStringKey,
        assets: [PHAsset],
        analyzer: SmartCleanAnalyzer,
        sizes: [String: Int64] = [:],
        measuresSizes: Bool = false,
        onHandled: @escaping @MainActor (Set<String>) -> Void = { _ in },
        @ViewBuilder header: () -> Header
    ) {
        self.title = title
        self.assets = assets
        self.analyzer = analyzer
        self.sizes = sizes
        self.measuresSizes = measuresSizes
        self.onHandled = onHandled
        self.header = header()
    }

    private var knownSizes: [String: Int64] {
        sizes.isEmpty ? measuredSizes : sizes
    }

    private var isSortable: Bool {
        !sizes.isEmpty || measuresSizes
    }

    /// Защищённые фото здесь не показываются: их нельзя отправить в корзину. Если фото защитили
    /// в полноэкранном просмотре прямо из сетки, оно сразу пропадает.
    private var visible: [PHAsset] {
        let policy = protection.policy
        return (ordered ?? assets).filter { !handled.contains($0.localIdentifier) && !policy.protects($0) }
    }

    /// Выбранные среди видимых: фото, удалённые снаружи после анализа, из выбора выпадают.
    private var selectedVisible: Set<String> {
        selection.intersection(visible.map(\.localIdentifier))
    }

    private var isAllSelected: Bool {
        !visible.isEmpty && selectedVisible.count == visible.count
    }

    private var selectedBytes: Int64 {
        let sizes = knownSizes
        return selectedVisible.reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    var body: some View {
        Group {
            if visible.isEmpty {
                ContentUnavailableView("Пусто", systemImage: "checkmark.seal", description: Text("Здесь больше нечего разбирать."))
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        // Заголовок раздела — секция сетки: так сетка остаётся ленивой и не грузит тысячи превью сразу.
                        LazyVGrid(columns: columns, spacing: 2) {
                            Section {
                                ForEach(visible, id: \.localIdentifier) { asset in
                                    cell(for: asset)
                                }
                            } header: {
                                header
                            }
                        }
                    }
                    actionBar
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

    /// Панель под сеткой: сколько весит выбранное (если размеры известны) и кнопки решения.
    private var actionBar: some View {
        VStack(spacing: 8) {
            // С известными размерами видно, сколько весит выбранное: строка есть всегда, чтобы сетка не прыгала.
            if !knownSizes.isEmpty {
                Group {
                    if selectedVisible.isEmpty {
                        Text("Отметьте, что убрать")
                    } else {
                        Text("Выбрано: \(selectedBytes.formattedBytes)")
                    }
                }
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("selection.selectedBytes")
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
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// Клетка сетки. Отдельная функция с типизированными значениями: одним выражением внутри `body`
    /// её не успевает типизировать компилятор Xcode 26, на котором собирается релиз.
    private func cell(for asset: PHAsset) -> some View {
        let isSelected = selection.contains(asset.localIdentifier)
        let size = knownSizes[asset.localIdentifier]
        let traits: AccessibilityTraits = isSelected ? [.isButton, .isSelected] : .isButton
        let label: Text = asset.mediaType == .video ? Text("Видео \(asset.duration.formattedDuration)") : Text("Фото")
        let value: Text = size.map { Text($0.formattedBytes) } ?? Text(verbatim: "")
        return AssetThumbnail(asset: asset, size: size)
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
            .accessibilityAddTraits(traits)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityAction(named: "Открыть") { fullScreen.asset = asset }
            .accessibilityIdentifier("selection.item")
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
        onHandled(ids)
    }
}

extension SelectionGridView where Header == EmptyView {
    init(title: LocalizedStringKey, assets: [PHAsset], analyzer: SmartCleanAnalyzer, sizes: [String: Int64] = [:], measuresSizes: Bool = false) {
        self.init(title: title, assets: assets, analyzer: analyzer, sizes: sizes, measuresSizes: measuresSizes) { EmptyView() }
    }
}
