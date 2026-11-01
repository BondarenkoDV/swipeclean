import Photos
import SwiftUI

/// Сжатие фото и видео: выбор уровня, оценка экономии, сжатие пачкой и удаление оригиналов одним подтверждением.
struct CompressView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case videos
        case photos

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .videos: "Видео"
            case .photos: "Фото"
            }
        }
    }

    private struct Candidate: Identifiable {
        let asset: PHAsset
        let size: Int64
        var id: String { asset.localIdentifier }
    }

    private struct Report {
        var saved: Int64 = 0
        var compressed = 0
        var skipped = 0
        var failed = 0
        var originalsDeleted = false
    }

    @Environment(PhotoLibraryService.self) private var library
    @Environment(FullScreenPresenter.self) private var fullScreen
    @AppStorage(SettingsKeys.compressionLevel) private var level = CompressionLevel.medium
    @AppStorage(SettingsKeys.deleteOriginalsAfterCompression) private var deleteOriginals = true
    @AppStorage(SettingsKeys.mediaSortOrder) private var sortOrder = MediaSortOrder.largest
    @State private var kind = Kind.videos
    @State private var candidates: [Candidate] = []
    @State private var isLoading = true
    @State private var selection: Set<String> = []
    @State private var progress: (done: Int, total: Int)?
    @State private var worker: Task<Void, Never>?
    @State private var report: Report?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]

    /// Фото меньше мегабайта почти не сжимаются, а Live Photos при сжатии потеряли бы видео.
    private nonisolated static let minimumPhotoSize: Int64 = 1_000_000
    private nonisolated static let photoLimit = 500

    private var selected: [Candidate] {
        candidates.filter { selection.contains($0.id) }
    }

    private var selectedBytes: Int64 {
        selected.reduce(0) { $0 + $1.size }
    }

    private var estimatedBytes: Int64 {
        selected.reduce(0) { $0 + MediaCompressor.estimatedSize(of: $1.asset, size: $1.size, level: level) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("Что сжимать", selection: $kind) {
                        ForEach(Kind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("compress.kind")

                    levelPicker
                    if let report {
                        reportCard(report)
                    }
                    grid
                }
                .padding(16)
            }
            bottomBar
        }
        .screenBackground()
        .navigationTitle("Сжатие")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                MediaSortMenu(order: $sortOrder)
                    .disabled(candidates.isEmpty || progress != nil)
                    .accessibilityIdentifier("compress.sort")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(selection.count == candidates.count && !candidates.isEmpty ? "Снять все" as LocalizedStringKey : "Выбрать все") {
                    if selection.count == candidates.count {
                        selection.removeAll()
                    } else {
                        selection = Set(candidates.map(\.id))
                    }
                }
                .disabled(candidates.isEmpty || progress != nil)
                .accessibilityIdentifier("compress.toggleAll")
            }
        }
        .task(id: kind) { await load() }
        .onChange(of: sortOrder) { _, _ in candidates = inSortOrder(candidates) }
        .onChange(of: library.changeCount) { _, _ in
            if progress == nil { Task { await load() } }
        }
        .onDisappear { worker?.cancel() }
        .interactiveDismissDisabled(progress != nil)
        .navigationBarBackButtonHidden(progress != nil)
    }

    private var levelPicker: some View {
        HStack(spacing: 8) {
            ForEach(CompressionLevel.allCases) { option in
                let isSelected = option == level
                Button {
                    level = option
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.title)
                            .font(.subheadline.bold())
                            .foregroundStyle(isSelected ? .white : .primary)
                        Text(kind == .videos ? option.videoDetail : option.photoDetail)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(isSelected ? AnyShapeStyle(Tone.green.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("compress.level.\(option.rawValue)")
            }
        }
        .disabled(progress != nil)
    }

    @ViewBuilder
    private var grid: some View {
        if isLoading {
            ProgressView("Считаю размеры файлов…")
                .padding(.top, 40)
        } else if candidates.isEmpty {
            ContentUnavailableView(
                kind == .videos ? "Видео нет" as LocalizedStringKey : "Крупных фото нет",
                systemImage: kind == .videos ? "video.slash" : "photo",
                description: Text(kind == .videos ? "В медиатеке нет видео." as LocalizedStringKey : "Сжимаются фото от 1 МБ. Live Photos не сжимаются, чтобы не потерять видео.")
            )
        } else {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(candidates) { candidate in
                    let isSelected = selection.contains(candidate.id)
                    AssetThumbnail(asset: candidate.asset, size: candidate.size)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Tone.green.color)
                                .shadow(color: .black.opacity(0.5), radius: 2)
                                .padding(6)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(candidate.id) }
                        .onLongPressGesture { fullScreen.asset = candidate.asset }
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(isSelected ? "Выбрано" : "Не выбрано")
                        .accessibilityValue(candidate.size.formattedBytes)
                        .accessibilityIdentifier("compress.item")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func reportCard(_ report: Report) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ToneIcon(symbol: report.compressed > 0 ? "checkmark.seal.fill" : "info", tone: report.compressed > 0 ? .green : .blue, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                if report.compressed > 0 {
                    Text("Сэкономлено \(report.saved.formattedBytes)")
                        .font(.headline)
                    Text(report.originalsDeleted
                         ? "Сжато: \(report.compressed). Оригиналы удалены, 30 дней они лежат в «Недавно удалённых»." as LocalizedStringKey
                         : "Сжато: \(report.compressed). Оригиналы остались в медиатеке рядом с копиями.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Ничего не сжато")
                        .font(.headline)
                }
                if report.skipped > 0 {
                    Text("Уже сжаты, копия не меньше: \(report.skipped)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if report.failed > 0 {
                    Text("Не удалось обработать: \(report.failed)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("compress.report")
    }

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let progress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Сжимаю \(progress.done + 1) из \(progress.total)")
                            .font(.subheadline.monospacedDigit())
                        Spacer()
                        Button("Отмена") { worker?.cancel() }
                            .font(.subheadline)
                    }
                    GradientBar(value: Double(progress.done) / Double(max(progress.total, 1)), gradient: Tone.green.gradient)
                }
            } else {
                Toggle("Удалить оригиналы после сжатия", isOn: $deleteOriginals)
                    .font(.subheadline)
                    .tint(Tone.green.color)
                    .accessibilityIdentifier("compress.deleteOriginals")
                Button(action: start) {
                    VStack(spacing: 2) {
                        Text("Сжать (\(selection.count))")
                        if !selection.isEmpty {
                            Text("\(selectedBytes.formattedBytes) → ≈ \(estimatedBytes.formattedBytes)")
                                .font(.caption.monospacedDigit())
                                .opacity(0.9)
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle(gradient: Tone.green.gradient))
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("compress.start")
            }
        }
        .padding(16)
        .background(.bar)
    }

    private func toggle(_ id: String) {
        guard progress == nil else { return }
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func load() async {
        isLoading = candidates.isEmpty
        let kind = kind
        let loaded = await Task.detached(priority: .userInitiated) { Self.fetchCandidates(kind) }.value
        guard !Task.isCancelled else { return }
        candidates = inSortOrder(loaded)
        selection.formIntersection(Set(loaded.map(\.id)))
        isLoading = false
    }

    /// По умолчанию самые тяжёлые сверху: с них экономия больше всего.
    private func inSortOrder(_ list: [Candidate]) -> [Candidate] {
        sortOrder.sorted(list) { MediaSortOrder.Key(id: $0.id, size: $0.size, date: $0.asset.creationDate) }
    }

    /// Фото берутся самые тяжёлые: с них экономия больше всего.
    private nonisolated static func fetchCandidates(_ kind: Kind) -> [Candidate] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: kind == .videos ? .video : .image, options: options)
        // Защищённые фото не сжимаются: сжатие заменяет оригинал копией.
        let protection = ProtectionPolicy.current
        var list: [Candidate] = []
        result.enumerateObjects { asset, _, _ in
            guard !protection.protects(asset) else { return }
            if kind == .photos {
                guard !asset.mediaSubtypes.contains(.photoLive) else { return }
            }
            let size = asset.cachedFileSize
            if kind == .photos, size < minimumPhotoSize { return }
            list.append(Candidate(asset: asset, size: size))
        }
        FileSizeCache.shared.save()
        list.sort { $0.size > $1.size }
        return kind == .photos ? Array(list.prefix(photoLimit)) : list
    }

    private func start() {
        let items = selected.map(\.asset)
        let level = level
        let deleteOriginals = deleteOriginals
        report = nil
        progress = (0, items.count)
        worker = Task {
            var report = Report()
            var originals: [String] = []
            for (index, asset) in items.enumerated() {
                if Task.isCancelled { break }
                progress = (index, items.count)
                do {
                    let outcome = try await MediaCompressor.compress(asset, level: level)
                    report.compressed += 1
                    report.saved += outcome.saved
                    originals.append(outcome.originalID)
                } catch MediaCompressor.Failure.notSmaller {
                    report.skipped += 1
                } catch is CancellationError {
                    break
                } catch {
                    report.failed += 1
                }
            }
            progress = nil
            selection.removeAll()
            if deleteOriginals, !originals.isEmpty {
                // Одно системное подтверждение на всю пачку. Если его отменить, остаются и оригиналы, и копии.
                report.originalsDeleted = (try? await LibraryEditor.deleteAssets(withIDs: originals)) != nil
            }
            withAnimation { self.report = report }
            await load()
        }
    }
}
