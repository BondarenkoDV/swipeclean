import Photos
import SwiftUI

/// Главная вкладка: подборки для разбора и список месяцев с прогрессом.
struct ReviewHomeView: View {
    @Environment(ReviewStore.self) private var store
    @Environment(PhotoLibraryService.self) private var library
    @State private var months: [MonthBucket] = []
    @State private var isLoading = true
    /// Снимок прогресса по месяцам. Считается при появлении экрана, а не на каждый свайп в открытой стопке.
    @State private var reviewed: [MonthBucket.ID: Int] = [:]

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(LibrarySource.featured + [.later]) { source in
                            NavigationLink(value: source) {
                                SourceTile(source: source)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("source.\(source.id)")
                        }
                    }

                    if isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        monthsSection
                    }
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle("Разбор")
            .navigationDestination(for: LibrarySource.self) { source in
                SourceDeckView(source: source)
            }
            .refreshable { await loadMonths() }
            .onAppear(perform: refreshProgress)
        }
        .task(id: library.changeCount) { await loadMonths() }
    }

    private var monthsSection: some View {
        let byYear = Dictionary(grouping: months, by: \.year)
        return ForEach(byYear.keys.sorted(by: >), id: \.self) { year in
            VStack(alignment: .leading, spacing: 8) {
                Text(String(year))
                    .font(.title2.bold())
                    .padding(.leading, 4)
                ForEach(byYear[year] ?? []) { bucket in
                    NavigationLink(value: bucket.source) {
                        MonthRow(bucket: bucket, reviewed: reviewed[bucket.id] ?? 0)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("month.\(bucket.id)")
                }
            }
        }
    }

    private func refreshProgress() {
        let ids = store.reviewedIDs
        reviewed = Dictionary(uniqueKeysWithValues: months.map { bucket in
            (bucket.id, bucket.assetIDs.reduce(0) { $0 + (ids.contains($1) ? 1 : 0) })
        })
    }

    private func loadMonths() async {
        let result = await Task.detached(priority: .userInitiated) { LibraryFetcher.months() }.value
        months = result
        refreshProgress()
        isLoading = false
    }
}

private struct SourceTile: View {
    let source: LibrarySource

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToneIcon(symbol: source.symbol, tone: source.tone, size: 40)
            Text(source.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .card(padding: 14, radius: 20)
    }
}

private extension LibrarySource {
    /// Свой цвет у каждой подборки, чтобы плитки различались с первого взгляда.
    var tone: Tone {
        switch self {
        case .all: .blue
        case .random: .violet
        case .onThisDay: .orange
        case .videos: .red
        case .screenshots: .pink
        case .selfies: .yellow
        case .livePhotos: .teal
        case .largeFiles: .indigo
        case .later: .cyan
        case .month, .album: .blue
        }
    }
}

private struct MonthRow: View {
    let bucket: MonthBucket
    let reviewed: Int

    private var total: Int { bucket.assetIDs.count }
    private var isDone: Bool { reviewed >= total }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(bucket.source.title)
                    .font(.body.weight(.semibold))
                GradientBar(value: Double(reviewed) / Double(max(total, 1)), gradient: isDone ? Tone.green.gradient : Palette.brand)
            }
            Text("\(reviewed) из \(total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: isDone ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(isDone ? Tone.green.color : Color.secondary)
        }
        .card(padding: 14, radius: 18)
    }
}
