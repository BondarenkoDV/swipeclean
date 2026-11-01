import Charts
import SwiftData
import SwiftUI

/// Статистика: освобождённое место, разобранные фото, стрики и прогресс по годам.
struct StatsView: View {
    @Environment(ReviewStore.self) private var store
    @Environment(PhotoLibraryService.self) private var library
    @Query(sort: \DailyStat.day) private var days: [DailyStat]
    @State private var buckets: [MonthBucket] = []
    @State private var years: [YearProgress] = []

    private var bytesFreed: Int64 { days.reduce(0) { $0 + $1.bytesFreed } }
    private var deletedCount: Int { days.reduce(0) { $0 + $1.trashed } }
    // Счётчики считаются в хранилище: загружать все записи в память ради двух чисел незачем.
    private var keptCount: Int { store.count(of: .keep, excludingDeleted: true) }
    private var favoriteCount: Int { store.count(of: .favorite) }

    private var streak: StatsCalculator.Streak {
        StatsCalculator.streak(activeDays: Set(days.filter(\.isActive).map(\.day)))
    }

    private var weekly: [StatsCalculator.WeekPoint] {
        StatsCalculator.weekly(days.map { ($0.day, $0.reviewed, $0.trashed) })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StatTile(title: "Разобрано", value: "\(store.reviewedIDs.count)", symbol: "rectangle.stack.fill", tone: .blue)
                        StatTile(title: "Удалено", value: "\(deletedCount)", symbol: "trash.fill", tone: .red)
                        StatTile(title: "Оставлено", value: "\(keptCount)", symbol: "checkmark", tone: .green)
                        StatTile(title: "В избранное", value: "\(favoriteCount)", symbol: "heart.fill", tone: .pink)
                        StatTile(title: "Стрик", value: StatsCalculator.daysText(streak.current), symbol: "flame.fill", tone: .orange)
                        StatTile(title: "Лучший стрик", value: StatsCalculator.daysText(streak.best), symbol: "trophy.fill", tone: .yellow)
                    }
                    weeklyChart
                    yearsSection
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle("Статистика")
            .task(id: library.changeCount) { await loadBuckets() }
            .refreshable { await loadBuckets() }
            .onChange(of: store.reviewedIDs.count) { _, _ in Task { await updateYears() } }
        }
    }

    private var hero: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.title2)
            Text("Освобождено")
                .font(.subheadline.weight(.medium))
                .opacity(0.9)
            Text(ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .gradientCard()
    }

    private var weeklyChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("По неделям")
                .font(.headline)
            Chart(weekly) { point in
                BarMark(
                    x: .value("Неделя", point.weekStart, unit: .weekOfYear),
                    y: .value("Разобрано", point.reviewed)
                )
                .foregroundStyle(Palette.brand)
                .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: 2)) {
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .frame(height: 160)
        }
        .card()
    }

    @ViewBuilder
    private var yearsSection: some View {
        if !years.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Прогресс по годам")
                    .font(.headline)
                ForEach(years) { year in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(String(year.year))
                            Spacer()
                            Text("\(year.reviewed) из \(year.total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        GradientBar(value: Double(year.reviewed) / Double(max(year.total, 1)))
                    }
                }
            }
            .card()
        }
    }

    private func loadBuckets() async {
        buckets = await Task.detached(priority: .utility) { LibraryFetcher.months() }.value
        await updateYears()
    }

    /// Пересчитывает прогресс по уже загруженным месяцам, не перечитывая медиатеку на каждый свайп.
    private func updateYears() async {
        let ids = store.reviewedIDs
        let buckets = buckets
        years = await Task.detached(priority: .utility) {
            Dictionary(grouping: buckets, by: \.year).map { year, buckets in
                let all = buckets.flatMap(\.assetIDs)
                return YearProgress(year: year, total: all.count, reviewed: all.filter { ids.contains($0) }.count)
            }
            .sorted { $0.year > $1.year }
        }.value
    }
}

private struct YearProgress: Identifiable {
    let year: Int
    let total: Int
    let reviewed: Int
    var id: Int { year }
}

private struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    let symbol: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 12) {
            ToneIcon(symbol: symbol, tone: tone, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3.bold().monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 12, radius: 18)
    }
}
