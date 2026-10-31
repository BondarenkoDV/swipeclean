import Charts
import Photos
import SwiftUI
import UIKit

/// Память iPhone подробно: из чего складывается занятое место и куда идти, чтобы его освободить.
/// iOS не показывает приложениям размеры других программ, поэтому точно измеряются медиатека по разделам,
/// сам SwipeClean и почта iCloud, а всё остальное честно показано одной строкой «Приложения и система».
struct StorageView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(ReviewStore.self) private var store
    @Environment(TabRouter.self) private var router
    @Environment(MailCleaner.self) private var mail
    @Environment(VaultStore.self) private var vault
    @State private var device: DeviceStorage?
    @State private var media: MediaBreakdown?
    @State private var app: AppFootprint?
    /// Доля, выбранная нажатием на диаграмму или легенду: её размер виден в центре круга.
    @State private var selectedSlice: String?

    /// Главная уже знает память и медиатеку: экран показывает их сразу и пересчитывает в фоне.
    init(device: DeviceStorage?, media: MediaBreakdown?) {
        _device = State(initialValue: device)
        _media = State(initialValue: media)
    }

    private var breakdown: StorageBreakdown? {
        guard let device, let media else { return nil }
        return StorageBreakdown(device: device, media: media.totalBytes, app: app?.total ?? 0)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                overviewCard
                if store.trashCount > 0 {
                    trashCard
                }
                mediaCard
                mailCard
                otherCard
                freeUpRow
                notes
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle("Память iPhone")
        .task(id: library.changeCount) { await refresh() }
        .task { await mail.loadQuota() }
        .refreshable { await refresh() }
    }

    // MARK: - Диаграмма

    /// Круговая диаграмма всей памяти и легенда. Нажатие на долю или строку легенды показывает её размер в центре.
    private var overviewCard: some View {
        VStack(spacing: 16) {
            if let device {
                donut(device)
                legend(device)
            } else {
                Text("Не удалось узнать размер памяти")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    /// Доли диаграммы: разделы медиатеки своими цветами, SwipeClean, приложения и система, свободное место.
    /// Вместе они дают всю память iPhone.
    private var slices: [StorageSlice] {
        guard let device, let breakdown, let media else { return [] }
        var slices = media.kinds.map { kind in
            StorageSlice(id: kind.rawValue, title: kind.title, bytes: breakdown.onDevice(media[kind].bytes), style: AnyShapeStyle(kind.tone.gradient))
        }
        if let app {
            slices.append(StorageSlice(id: "app", title: "SwipeClean", bytes: app.total, style: AnyShapeStyle(Palette.brand)))
        }
        slices.append(StorageSlice(id: "other", title: "Приложения и система", bytes: breakdown.other, style: AnyShapeStyle(Color(.systemGray2))))
        slices.append(StorageSlice(id: "free", title: "Свободно", bytes: device.available, style: AnyShapeStyle(Color(.systemGray5))))
        return slices.filter { $0.bytes > 0 }
    }

    private func donut(_ device: DeviceStorage) -> some View {
        let slices = slices
        return Chart(slices) { slice in
            SectorMark(
                angle: .value("Размер", Double(slice.bytes)),
                innerRadius: .ratio(0.66),
                angularInset: 1.2
            )
            .cornerRadius(4)
            .foregroundStyle(slice.style)
            .opacity(selectedSlice == nil || selectedSlice == slice.id ? 1 : 0.3)
        }
        .chartLegend(.hidden)
        // Нажатие, а не встроенный выбор угла: тот перехватывает протягивание, и экран переставал бы листаться с диаграммы.
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let frame = geometry[plotFrame]
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            select(at: location, in: frame, slices: slices)
                        }
                }
            }
        }
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let frame = geometry[plotFrame]
                    donutCenter(device, slices: slices)
                        .frame(width: frame.width * 0.56)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .frame(height: 260)
        .animation(.smooth, value: selectedSlice)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Занято \(device.used.formattedBytes) из \(device.total.formattedBytes)"))
        .accessibilityIdentifier("storage.overview")
    }

    /// В центре круга: занятое место или размер выбранной доли.
    @ViewBuilder
    private func donutCenter(_ device: DeviceStorage, slices: [StorageSlice]) -> some View {
        if let slice = slices.first(where: { $0.id == selectedSlice }) {
            VStack(spacing: 2) {
                Text(slice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(slice.bytes.formattedBytes)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(share(slice.bytes, of: device.total))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 2) {
                Text("Занято")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(device.used.formattedBytes)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Text("из \(device.total.formattedBytes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Выбирает долю под пальцем. Доли идут по часовой стрелке от двенадцати часов; нажатие в центр
    /// или мимо круга, как и повторное нажатие на ту же долю, снимает выбор.
    private func select(at location: CGPoint, in frame: CGRect, slices: [StorageSlice]) {
        let dx = location.x - frame.midX
        let dy = location.y - frame.midY
        let radius = min(frame.width, frame.height) / 2
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance <= radius, distance >= radius * 0.55 else {
            selectedSlice = nil
            return
        }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let id = slice(at: angle / (2 * .pi), in: slices)?.id
        selectedSlice = selectedSlice == id ? nil : id
    }

    /// Доля, на которую приходится точка круга: `fraction` от 0 до 1, нарастающим итогом от начала круга.
    private func slice(at fraction: Double, in slices: [StorageSlice]) -> StorageSlice? {
        let total = slices.reduce(0.0) { $0 + Double($1.bytes) }
        var sum = 0.0
        for slice in slices {
            sum += Double(slice.bytes)
            if fraction * total <= sum { return slice }
        }
        return slices.last
    }

    private func share(_ bytes: Int64, of total: Int64) -> String {
        (total > 0 ? Double(bytes) / Double(total) : 0).formatted(.percent.precision(.fractionLength(0)))
    }

    private func legend(_ device: DeviceStorage) -> some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(slices) { slice in
                Button {
                    selectedSlice = selectedSlice == slice.id ? nil : slice.id
                } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Circle()
                            .fill(slice.style)
                            .frame(width: 11, height: 11)
                            .padding(.top, 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(slice.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            HStack(spacing: 4) {
                                Text(slice.bytes.formattedBytes)
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.primary)
                                Text(share(slice.bytes, of: device.total))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        selectedSlice == slice.id ? Color(.tertiarySystemFill) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("storage.legend.\(slice.id)")
            }
        }
    }

    // MARK: - Корзина

    private var trashCard: some View {
        let bytes = store.trashItems().reduce(Int64(0)) { $0 + $1.fileSize }
        return Button {
            router.tab = .trash
        } label: {
            HStack(spacing: 12) {
                ToneIcon(symbol: "trash.fill", tone: .red, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Корзина SwipeClean: \(bytes.formattedBytes)")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Фото и видео к удалению: \(store.trashCount). Место освободится, когда вы удалите их из корзины.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .card(padding: 14)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("storage.trash")
    }

    // MARK: - Медиатека

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Фото и видео", detail: media.map { $0.totalBytes.formattedBytes })
            if let media {
                if media.totalCount == 0 {
                    Text("В медиатеке пока нет фото и видео.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    let largest = media.kinds.first.map { media[$0].bytes } ?? 0
                    ForEach(media.kinds) { kind in
                        mediaRow(kind, usage: media[kind], total: media.totalBytes, largest: largest)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Считаю размеры фото и видео. Первый раз на большой медиатеке это может занять минуту.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
        .card()
        // Иначе идентификатор карточки достаётся каждой строке и заменяет их собственные storage.kind.*.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storage.media")
    }

    @ViewBuilder
    private func mediaRow(_ kind: MediaKind, usage: MediaBreakdown.Usage, total: Int64, largest: Int64) -> some View {
        let row = UsageRow(
            symbol: kind.symbol,
            tone: kind.tone,
            title: kind.title,
            subtitle: kind.isVideo ? "\(usage.count) видео" as LocalizedStringKey : "\(usage.count) фото",
            bytes: usage.bytes,
            share: total > 0 ? Double(usage.bytes) / Double(total) : 0,
            bar: largest > 0 ? Double(usage.bytes) / Double(largest) : 0,
            hasChevron: kind != .hidden
        )
        switch kind {
        case .hidden:
            // Скрытые в Фото закрыты Face ID: здесь только их размер, без просмотра.
            row
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("storage.kind.\(kind.rawValue)")
        case .bursts:
            // Серии разбираются умной чисткой: она оставляет лучший кадр каждой серии.
            NavigationLink {
                SmartCleanView()
            } label: {
                row
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("storage.kind.\(kind.rawValue)")
        default:
            NavigationLink {
                MediaKindView(kind: kind)
            } label: {
                row
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("storage.kind.\(kind.rawValue)")
        }
    }

    // MARK: - Почта

    private var mailFoundCount: Int {
        MailCategory.allCases.reduce(0) { $0 + mail.active(in: $1).count }
    }

    private var mailCard: some View {
        NavigationLink {
            MailCleanView()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ToneIcon(symbol: "envelope.fill", tone: .blue, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Почта iCloud")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Хранится в iCloud, а не в памяти iPhone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                if !mail.isConnected {
                    Text("Подключите почту, чтобы увидеть, сколько она занимает, и убрать спам и рассылки.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                } else {
                    if let quota = mail.quota {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("По данным сервера")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(quota.used.formattedBytes) из \(quota.limit.formattedBytes)")
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                            }
                            .font(.subheadline)
                            GradientBar(value: quota.fraction, gradient: Tone.blue.gradient, height: 6)
                        }
                    }
                    if mail.state == .finished, mailFoundCount > 0 {
                        Text("Лишних писем: \(mailFoundCount) · \(mail.totalBytes.formattedBytes)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Tone.blue.color)
                    } else {
                        Text("Найти спам, рассылки и тяжёлые письма")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Tone.blue.color)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("storage.mail")
    }

    // MARK: - Остальное

    private var otherCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Остальное", detail: nil)
            UsageRow(
                symbol: "sparkles",
                tone: .violet,
                title: "SwipeClean",
                subtitle: "Приложение, кэш анализа и настройки",
                bytes: app?.other,
                hasChevron: false
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("storage.app")
            if let vaultBytes = app?.vault, vaultBytes > 0 {
                NavigationLink {
                    VaultView()
                } label: {
                    UsageRow(symbol: "lock.fill", tone: .indigo, title: "Секретная папка", subtitle: "Фото и видео внутри SwipeClean", bytes: vaultBytes)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("storage.vault")
            }
            UsageRow(
                symbol: "apps.iphone",
                tone: nil,
                title: "Приложения и система",
                subtitle: "iOS, другие приложения, их данные и кэши",
                bytes: app == nil ? nil : breakdown?.other,
                hasChevron: false
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("storage.other")
            if let purgeable = device?.purgeable, purgeable >= 100_000_000 {
                UsageRow(
                    symbol: "arrow.3.trianglepath",
                    tone: .green,
                    title: "Кэш, который iOS удалит сама",
                    subtitle: "Уже входит в свободное место",
                    bytes: purgeable,
                    hasChevron: false
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("storage.purgeable")
            }
            Text("iOS не даёт приложениям узнать, сколько занимают другие программы. Разбивка по приложениям — в Настройках → Основные → Хранилище iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .card()
    }

    // MARK: - Как освободить место

    private var freeUpRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Освободить место")
                .font(.title3.bold())
                .padding(.leading, 4)
            HStack(spacing: 10) {
                NavigationLink {
                    SmartCleanView()
                } label: {
                    ActionTile(title: "Умная чистка", symbol: "wand.and.stars", tone: .violet)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("storage.smartClean")
                Button {
                    router.tab = .review
                } label: {
                    ActionTile(title: "Свайп-разбор", symbol: "hand.draw.fill", tone: .orange)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("storage.swipe")
                NavigationLink {
                    CompressView()
                } label: {
                    ActionTile(title: "Сжатие", symbol: "arrow.down.right.and.arrow.up.left", tone: .green)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("storage.compress")
            }
        }
    }

    // MARK: - Пояснения

    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            if breakdown?.isMediaPartlyInCloud == true {
                Label("Оригиналы фото и видео больше, чем занято на iPhone: часть из них хранится только в iCloud (включена «Оптимизация хранилища»).", systemImage: "icloud")
            }
            Label("Размеры фото и видео — это размеры оригиналов вместе с видео Live Photos и версиями с правками. С «Оптимизацией хранилища» на iPhone они занимают меньше.", systemImage: "info.circle")
            VStack(alignment: .leading, spacing: 6) {
                Label("Удалённые фото ещё 30 дней лежат в альбоме «Недавно удалённые» и занимают место. Чтобы освободить его сразу, очистите этот альбом в Фото.", systemImage: "clock.arrow.circlepath")
                if let url = URL(string: "photos-redirect://") {
                    Button("Открыть Фото") { UIApplication.shared.open(url) }
                        .font(.caption.weight(.semibold))
                        .padding(.leading, 28)
                        .accessibilityIdentifier("storage.openPhotos")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func refresh() async {
        device = DeviceStorage.current()
        let vaultDirectory = vault.directory
        // Папки SwipeClean и медиатека считаются одновременно: в кэше анализа тысячи мелких файлов.
        let footprint = Task.detached(priority: .utility) { AppFootprint.measure(vaultDirectory: vaultDirectory) }
        let measured = await Task.detached(priority: .userInitiated) { MediaBreakdown.measure() }.value
        guard !Task.isCancelled else { return }
        withAnimation { media = measured }
        let measuredApp = await footprint.value
        guard !Task.isCancelled else { return }
        withAnimation { app = measuredApp }
    }
}

// MARK: - Элементы

/// Доля круговой диаграммы памяти.
private struct StorageSlice: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let bytes: Int64
    let style: AnyShapeStyle
}

private struct SectionHeader: View {
    let title: LocalizedStringKey
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.bold())
            Spacer()
            if let detail {
                Text(detail)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 6)
    }
}

/// Строка раздела: значок, название, сколько штук, размер и доля полоской.
private struct UsageRow: View {
    let symbol: String
    /// nil — серый значок для того, что не измеряется по отдельности.
    let tone: Tone?
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let bytes: Int64?
    var share: Double?
    var bar: Double?
    var hasChevron = true

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if let tone {
                    ToneIcon(symbol: symbol, tone: tone, size: 36)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color(.systemGray), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    if let bytes {
                        Text(bytes.formattedBytes)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if let share {
                        Text(share.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if hasChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            if let bar, let tone {
                GradientBar(value: bar, gradient: tone.gradient, height: 5)
                    .padding(.leading, 48)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Плитка действия внизу экрана.
private struct ActionTile: View {
    let title: LocalizedStringKey
    let symbol: String
    let tone: Tone

    var body: some View {
        VStack(spacing: 8) {
            ToneIcon(symbol: symbol, tone: tone, size: 40)
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 84)
        .card(padding: 10, radius: 18)
        .contentShape(Rectangle())
    }
}
