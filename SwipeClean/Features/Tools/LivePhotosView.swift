import Photos
import SwiftUI

/// Live Photos → обычные фото: выбрать, увидеть, сколько освободится, и одним подтверждением оставить только снимки.
struct LivePhotosView: View {
    private enum Phase: Equatable {
        case preparing(done: Int, total: Int)
        /// Снимки готовы, ждём ответа в системном окне подтверждения.
        case confirming
    }

    private struct Report {
        var converted = 0
        var saved: Int64 = 0
        var failed = 0
        /// Отменено в системном окне или кнопкой «Отмена»: текущая пачка не тронута.
        var cancelled = false
        /// Следующей пачке не хватило свободного места.
        var stoppedForSpace = false
    }

    private struct SpaceIssue {
        let needed: Int64
        let available: Int64
    }

    @Environment(PhotoLibraryService.self) private var library
    @Environment(ReviewStore.self) private var store
    @Environment(FullScreenPresenter.self) private var fullScreen
    @AppStorage(SettingsKeys.mediaSortOrder) private var sortOrder = MediaSortOrder.largest
    @State private var candidates: [LivePhotoConverter.Candidate] = []
    @State private var isLoading = true
    @State private var selection: Set<String> = []
    @State private var phase: Phase?
    @State private var worker: Task<Void, Never>?
    @State private var report: Report?
    @State private var spaceIssue: SpaceIssue?
    @State private var seedError: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]

    private var selected: [LivePhotoConverter.Candidate] {
        candidates.filter { selection.contains($0.id) }
    }

    private var totalSavings: Int64 {
        candidates.reduce(0) { $0 + $1.savings }
    }

    private var selectedSavings: Int64 {
        selected.reduce(0) { $0 + $1.savings }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    summaryCard
                    if let report {
                        reportCard(report)
                    }
                    if let seedError {
                        Text(seedError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("live.seedError")
                    }
                    grid
                }
                .padding(16)
            }
            bottomBar
        }
        .screenBackground()
        .navigationTitle("Live Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                MediaSortMenu(order: $sortOrder)
                    .disabled(candidates.isEmpty || phase != nil)
                    .accessibilityIdentifier("live.sort")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(selection.count == candidates.count && !candidates.isEmpty ? "Снять все" as LocalizedStringKey : "Выбрать все") {
                    if selection.count == candidates.count {
                        selection.removeAll()
                    } else {
                        selection = Set(candidates.map(\.id))
                    }
                }
                .disabled(candidates.isEmpty || phase != nil)
                .accessibilityIdentifier("live.toggleAll")
            }
        }
        .task { await load() }
        .onChange(of: sortOrder) { _, _ in candidates = inSortOrder(candidates) }
        .onChange(of: library.changeCount) { _, _ in
            if phase == nil { Task { await load() } }
        }
        .onDisappear { worker?.cancel() }
        .navigationBarBackButtonHidden(phase != nil)
        .alert(
            "Не хватает места",
            isPresented: Binding(get: { spaceIssue != nil }, set: { if !$0 { spaceIssue = nil } }),
            presenting: spaceIssue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { issue in
            Text("Для новых фото нужно \(issue.needed.formattedBytes), свободно \(issue.available.formattedBytes). Выберите меньше фото или очистите «Недавно удалённые» в «Фото».")
        }
    }

    // MARK: - Сводка

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "livephoto")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live Photos: \(candidates.count)")
                        .font(.title3.bold())
                        .monospacedDigit()
                    if isLoading {
                        Text("Считаю размеры…")
                            .font(.subheadline)
                            .opacity(0.9)
                    } else {
                        Text("Видео в них ≈ \(totalSavings.formattedBytes)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .opacity(0.95)
                    }
                }
                Spacer(minLength: 0)
            }
            Text("Каждое Live Photo хранит рядом со снимком 3 секунды видео. Останется только снимок в исходном качестве — с датой, местом, избранным и альбомами. На превью — сколько освободится.")
                .font(.footnote)
                .opacity(0.9)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .gradientCard(Tone.orange.gradient)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("live.summary")
    }

    @ViewBuilder
    private var grid: some View {
        if isLoading {
            ProgressView("Ищу Live Photos…")
                .padding(.top, 40)
        } else if candidates.isEmpty {
            ContentUnavailableView(
                "Live Photos нет",
                systemImage: "livephoto.slash",
                description: Text("Все фото уже обычные: превращать нечего.")
            )
            .accessibilityIdentifier("live.empty")
        } else {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(candidates) { candidate in
                    let isSelected = selection.contains(candidate.id)
                    AssetThumbnail(asset: candidate.asset, size: candidate.savings)
                        .overlay(alignment: .topLeading) {
                            Image(systemName: "livephoto")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.5), radius: 2)
                                .padding(6)
                        }
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Tone.orange.color)
                                .shadow(color: .black.opacity(0.5), radius: 2)
                                .padding(6)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(candidate.id) }
                        .onLongPressGesture { fullScreen.asset = candidate.asset }
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(isSelected ? "Выбрано" : "Не выбрано")
                        .accessibilityValue(candidate.savings.formattedBytes)
                        .accessibilityIdentifier("live.item")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func reportCard(_ report: Report) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ToneIcon(symbol: report.converted > 0 ? "checkmark.seal.fill" : "info", tone: report.converted > 0 ? .green : .blue, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                if report.converted > 0 {
                    Text("Сэкономлено \(report.saved.formattedBytes)")
                        .font(.headline)
                    Text("Стали обычными фото: \(report.converted). Оригиналы 30 дней лежат в «Недавно удалённых»: очистите их в «Фото», чтобы место освободилось сразу.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if report.cancelled {
                    Text("Отменено, ничего не изменилось")
                        .font(.headline)
                } else {
                    Text("Ничего не изменилось")
                        .font(.headline)
                }
                if report.converted > 0, report.cancelled {
                    Text("Остальные отменены и остались Live Photos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if report.stoppedForSpace {
                    Text("Остановлено: не хватило свободного места для следующих фото.")
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
        .accessibilityIdentifier("live.report")
    }

    // MARK: - Нижняя панель

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 10) {
            switch phase {
            case let .preparing(done, total)?:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Готовлю фото \(min(done + 1, total)) из \(total)")
                            .font(.subheadline.monospacedDigit())
                        Spacer()
                        Button("Отмена") { worker?.cancel() }
                            .font(.subheadline)
                            .accessibilityIdentifier("live.cancel")
                    }
                    GradientBar(value: Double(done) / Double(max(total, 1)), gradient: Tone.orange.gradient)
                }
            case .confirming?:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Подтвердите удаление оригиналов в системном окне")
                        .font(.subheadline)
                    Spacer(minLength: 0)
                }
            case nil:
                Button(action: start) {
                    VStack(spacing: 2) {
                        Text("Оставить только фото (\(selection.count))")
                        if !selection.isEmpty {
                            Text("Освободится ≈ \(selectedSavings.formattedBytes)")
                                .font(.caption.monospacedDigit())
                                .opacity(0.9)
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle(gradient: Tone.orange.gradient))
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("live.start")
                Text("Оригиналы уйдут в «Недавно удалённые» одним подтверждением")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.bar)
    }

    // MARK: - Действия

    private func toggle(_ id: String) {
        guard phase == nil else { return }
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func load() async {
        #if DEBUG
        if let error = await LivePhotoSeeder.seedOnce() {
            seedError = error
        }
        #endif
        isLoading = candidates.isEmpty
        let loaded = await Task.detached(priority: .userInitiated) { LivePhotoConverter.fetchCandidates() }.value
        guard !Task.isCancelled else { return }
        candidates = inSortOrder(loaded)
        selection.formIntersection(Set(loaded.map(\.id)))
        isLoading = false
    }

    /// По умолчанию самые тяжёлые сверху: у них больше всего видео.
    private func inSortOrder(_ list: [LivePhotoConverter.Candidate]) -> [LivePhotoConverter.Candidate] {
        sortOrder.sorted(list) { MediaSortOrder.Key(id: $0.id, size: $0.savings, date: $0.asset.creationDate) }
    }

    private func start() {
        let items = selected
        guard !items.isEmpty else { return }
        let firstBatch = LivePhotoConverter.batches(items).first ?? []
        let needed = firstBatch.reduce(Int64(0)) { $0 + $1.still }
        let available = DeviceStorage.current()?.available
        guard LivePhotoConverter.hasRoom(forStills: needed, available: available) else {
            spaceIssue = SpaceIssue(needed: needed + LivePhotoConverter.spaceMargin, available: available ?? 0)
            return
        }
        report = nil
        phase = .preparing(done: 0, total: items.count)
        worker = Task {
            let report = await convert(items)
            phase = nil
            selection.removeAll()
            withAnimation { self.report = report }
            // Отменённая задача не обновила бы список: перечитываем в новой.
            Task { await load() }
        }
    }

    /// Пачками: снимки пачки выгружаются во временную папку, затем одна транзакция заменяет оригиналы.
    private func convert(_ items: [LivePhotoConverter.Candidate]) async -> Report {
        var report = Report()
        guard let directory = try? LivePhotoConverter.makeWorkDirectory() else {
            report.failed = items.count
            return report
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        var done = 0
        for batch in LivePhotoConverter.batches(items) {
            if Task.isCancelled {
                report.cancelled = true
                break
            }
            if done > 0 {
                let needed = batch.reduce(Int64(0)) { $0 + $1.still }
                guard LivePhotoConverter.hasRoom(forStills: needed, available: DeviceStorage.current()?.available) else {
                    report.stoppedForSpace = true
                    break
                }
            }
            var stills: [LivePhotoConverter.PreparedStill] = []
            for candidate in batch {
                if Task.isCancelled { break }
                phase = .preparing(done: done, total: items.count)
                do {
                    let still = try await LivePhotoConverter.prepareStill(for: candidate.asset, in: directory)
                    stills.append(still)
                } catch {
                    report.failed += 1
                }
                done += 1
            }
            if Task.isCancelled {
                report.cancelled = true
                break
            }
            phase = .confirming
            do {
                let outcome = try await LivePhotoConverter.commit(stills)
                report.converted += outcome.replaced.count
                report.saved += outcome.saved
                let sizes = Dictionary(
                    stills.compactMap { still in outcome.replaced[still.originalID].map { ($0, still.size) } },
                    uniquingKeysWith: { first, _ in first }
                )
                store.transfer(outcome.replaced, sizes: sizes)
            } catch {
                if LivePhotoConverter.isUserCancel(error) {
                    report.cancelled = true
                } else {
                    report.failed += stills.count
                }
                break
            }
            for still in stills {
                try? FileManager.default.removeItem(at: still.url)
            }
        }
        return report
    }
}
