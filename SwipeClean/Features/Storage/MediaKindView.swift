import LocalAuthentication
import Photos
import SwiftUI

/// Раздел памяти подробно: сколько весит каждая группа по размеру и сами фото и видео, самые тяжёлые первыми.
/// Группу можно оставить в сетке одну, выбрать в ней всё и отправить в корзину.
struct MediaKindView: View {
    let kind: MediaKind

    @Environment(SmartCleanAnalyzer.self) private var analyzer
    @Environment(ReviewStore.self) private var store
    /// Фото и видео раздела, кроме уже отправленных в корзину SwipeClean.
    @State private var items: [Item]?
    @State private var sizes: [String: Int64] = [:]
    /// Группа по размеру, которая одна осталась в сетке.
    @State private var bucket: SizeBucket?
    /// Скрытые открываются после Face ID, как в Фото.
    @State private var isUnlocked = false

    private struct Item {
        let asset: PHAsset
        let size: Int64
    }

    private var isLocked: Bool {
        kind == .hidden && !isUnlocked
    }

    private var shown: [PHAsset] {
        guard let items else { return [] }
        guard let bucket else { return items.map(\.asset) }
        return items.filter { bucket.contains($0.size) }.map(\.asset)
    }

    var body: some View {
        Group {
            if isLocked {
                ContentUnavailableView {
                    Label("Скрытые закрыты", systemImage: "eye.slash.fill")
                } description: {
                    Text("Как и в Фото, они открываются после Face ID или код-пароля.")
                } actions: {
                    Button("Открыть") { Task { await open() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("kind.unlock")
                }
                .navigationTitle(kind.title)
                .navigationBarTitleDisplayMode(.inline)
            } else if let items {
                SelectionGridView(title: kind.title, assets: shown, analyzer: analyzer, sizes: sizes, onHandled: handle) {
                    header(MediaKindSummary(sizes: items.map(\.size), isVideo: kind.isVideo))
                }
            } else {
                ProgressView("Считаю размеры…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(kind.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // У Live Photos можно убрать только видео, оставив снимки: место освобождается без удаления фото.
            if kind == .livePhotos {
                NavigationLink {
                    LivePhotosView()
                } label: {
                    HStack(spacing: 10) {
                        ToneIcon(symbol: "livephoto.slash", tone: .orange, size: 32)
                        Text("Оставить только фото, без видео")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("kind.livePhotos.convert")
            }
        }
        .task { await open() }
    }

    // MARK: - Сводка

    /// Над сеткой: размер раздела, сколько весят самые большие файлы и группы по размеру.
    private func header(_ summary: MediaKindSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ToneIcon(symbol: kind.symbol, tone: kind.tone, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.bytes.formattedBytes)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .monospacedDigit()
                    Text(kind.isVideo ? "\(summary.count) видео" as LocalizedStringKey : "\(summary.count) фото")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("kind.summary")
            if summary.count > MediaKindSummary.topCount {
                Label {
                    Text("10 самых больших занимают \(summary.topBytes.formattedBytes), это \(share(summary.topBytes, of: summary.bytes)) раздела")
                } icon: {
                    Image(systemName: "chart.bar.fill")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(kind.tone.color)
                .accessibilityIdentifier("kind.top")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("По размеру")
                    .font(.headline)
                    .padding(.bottom, 4)
                ForEach(summary.filledGroups) { group in
                    bucketRow(group, total: summary.bytes)
                }
            }
            Text(bucket == nil
                 ? "Нажмите на группу, чтобы оставить в сетке только её." as LocalizedStringKey
                 : "«Выбрать все» отметит только эту группу. Нажмите на неё ещё раз, чтобы показать все.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if kind == .bursts {
                // Серии лучше разбирать умной чисткой: она оставит лучший кадр каждой серии.
                NavigationLink {
                    SmartCleanView()
                } label: {
                    Label("Лучший кадр каждой серии оставит умная чистка", systemImage: "wand.and.stars")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Tone.violet.color)
                }
                .accessibilityIdentifier("kind.smartClean")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// Группа по размеру: нажатие оставляет в сетке только её, повторное возвращает все.
    private func bucketRow(_ group: MediaKindSummary.Group, total: Int64) -> some View {
        let isSelected = bucket == group.bucket
        // Значения с явными типами: длинную цепочку модификаторов иначе не успевает типизировать Xcode 26 релизной сборки.
        let count: Text = kind.isVideo ? Text("\(group.count) видео") : Text("\(group.count) фото")
        let fraction: Double = total > 0 ? Double(group.bytes) / Double(total) : 0
        let fill: Color = isSelected ? kind.tone.color.opacity(0.14) : .clear
        let traits: AccessibilityTraits = isSelected ? .isSelected : []
        return Button {
            withAnimation(.snappy) { bucket = isSelected ? nil : group.bucket }
        } label: {
            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? kind.tone.color : Color(.tertiaryLabel))
                    Text(group.bucket.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    count
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(group.bytes.formattedBytes)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                GradientBar(value: fraction, gradient: kind.tone.gradient, height: 5)
                    .padding(.leading, 28)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(bucket == nil || isSelected ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(traits)
        .accessibilityIdentifier("kind.bucket.\(group.bucket.lower)")
    }

    private func share(_ bytes: Int64, of total: Int64) -> String {
        (total > 0 ? Double(bytes) / Double(total) : 0).formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: - Загрузка

    /// Скрытые в Фото закрыты Face ID, здесь так же. Если на iPhone нет код-пароля, Фото тоже показывает их сразу.
    private func open() async {
        if kind == .hidden, !isUnlocked {
            let context = LAContext()
            if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
                let reason = String(localized: "Показать скрытые фото и видео")
                isUnlocked = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
            } else {
                isUnlocked = true
            }
        }
        guard !isLocked else { return }
        await load()
    }

    private func load() async {
        guard items == nil else { return }
        let kind = kind
        let loaded = await Task.detached(priority: .userInitiated) { MediaKind.assets(of: kind) }.value
        guard !Task.isCancelled else { return }
        // То, что уже ждёт удаления в корзине SwipeClean, второй раз не предлагается.
        let trashed = Set(store.trashItems().map(\.localIdentifier))
        let fresh = loaded.filter { !trashed.contains($0.asset.localIdentifier) }
        sizes = Dictionary(fresh.map { ($0.asset.localIdentifier, $0.size) }, uniquingKeysWith: { first, _ in first })
        items = fresh.map { Item(asset: $0.asset, size: $0.size) }
    }

    /// Разобранное уходит из сводки. Если выбранная группа опустела, сетка снова показывает весь раздел.
    private func handle(_ ids: Set<String>) {
        items?.removeAll { ids.contains($0.asset.localIdentifier) }
        if let bucket, !(items ?? []).contains(where: { bucket.contains($0.size) }) {
            self.bucket = nil
        }
    }
}
