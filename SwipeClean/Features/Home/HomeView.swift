import Photos
import SwiftUI

/// Куда можно перейти с главной.
enum HomeRoute: Hashable {
    case smartClean
    case compress
    case vault
    case contacts
    case calendar
    case mail
    case storage
}

/// Главная: память iPhone, умная чистка одной кнопкой, свайп-разбор и инструменты.
struct HomeView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(SmartCleanAnalyzer.self) private var analyzer
    @Environment(ReviewStore.self) private var store
    @Environment(TabRouter.self) private var router
    @Environment(MailCleaner.self) private var mail
    @AppStorage(SettingsKeys.smartCleanPeriod) private var period = SmartCleanPeriod.all
    @AppStorage(SettingsKeys.mailPeriod) private var mailPeriod = SmartCleanPeriod.all
    @State private var isPickingPeriod = false
    @State private var isPickingMailPeriod = false
    @State private var storage = DeviceStorage.current()
    @State private var media = MediaSummary()
    @State private var path: [HomeRoute] = []

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    storageCard
                    smartCleanCard
                    swipeCard
                    toolsGrid
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle("SwipeClean")
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .smartClean: SmartCleanView()
                case .compress: CompressView()
                case .vault: VaultView()
                case .contacts: ContactsCleanView()
                case .calendar: CalendarCleanView()
                case .mail: MailCleanView()
                case .storage: StorageView(device: storage, media: media.breakdown)
                }
            }
            .refreshable { await refresh() }
        }
        .task(id: library.changeCount) { await refresh() }
        // Период выбирается прямо на главной: умная чистка ищет ровно за то, что здесь написано.
        .onChange(of: period) { analyzer.reset() }
        .onChange(of: mailPeriod) { mail.scanIfNeeded(interval: mailPeriod.interval()) }
        .sheet(isPresented: $isPickingPeriod) {
            PeriodPickerView(selection: $period)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $isPickingMailPeriod) {
            PeriodPickerView(selection: $mailPeriod)
                .presentationDetents([.large])
        }
    }

    // MARK: - Память

    /// Кольцо занятой памяти и полоса «фото и видео / остальное / свободно». Нажатие открывает подробную разбивку.
    private var storageCard: some View {
        Button {
            path.append(.storage)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    ZStack {
                        ProgressRing(progress: storage?.usedFraction ?? 0)
                        VStack(spacing: 0) {
                            Text((storage?.usedFraction ?? 0).formatted(.percent.precision(.fractionLength(0))))
                                .font(.system(.title2, design: .rounded, weight: .bold))
                                .monospacedDigit()
                            Text("занято")
                                .font(.caption2)
                                .opacity(0.85)
                        }
                    }
                    .frame(width: 104, height: 104)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Память iPhone")
                            .font(.subheadline.weight(.medium))
                            .opacity(0.85)
                        if let storage {
                            Text("Свободно \(storage.available.formattedBytes)")
                                .font(.title3.bold())
                                .minimumScaleFactor(0.8)
                                .lineLimit(1)
                            Text("из \(storage.total.formattedBytes)")
                                .font(.subheadline)
                                .opacity(0.85)
                        }
                        Divider().overlay(.white.opacity(0.4))
                        Group {
                            if let bytes = media.bytes {
                                Text("Фото и видео: \(bytes.formattedBytes)")
                            } else {
                                Text("Фото и видео: считаю…")
                            }
                            Text("\(media.photos) фото · \(media.videos) видео")
                                .opacity(0.85)
                        }
                        .font(.footnote.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let storage, let bytes = media.bytes {
                    storageBar(StorageBreakdown(device: storage, media: bytes, app: 0))
                }
            }
            .gradientCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.storage")
    }

    /// Белая полоса на градиенте: ярко — фото и видео, бледнее — приложения и система, пусто — свободно.
    private func storageBar(_ breakdown: StorageBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Capsule()
                        .fill(.white)
                        .frame(width: proxy.size.width * breakdown.fraction(breakdown.mediaOnDevice))
                    Capsule()
                        .fill(.white.opacity(0.55))
                        .frame(width: proxy.size.width * breakdown.fraction(breakdown.other))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 10)
            .background(.white.opacity(0.22), in: Capsule())
            .accessibilityHidden(true)
            HStack(spacing: 12) {
                legendDot("Фото и видео", opacity: 1)
                legendDot("Приложения и система", opacity: 0.55)
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    Text("Подробнее")
                    Image(systemName: "chevron.right")
                }
                .font(.caption.weight(.semibold))
            }
        }
    }

    private func legendDot(_ title: LocalizedStringKey, opacity: Double) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.white.opacity(opacity))
                .frame(width: 8, height: 8)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.caption2.weight(.medium))
    }

    // MARK: - Умная чистка

    private var foundExtras: Int {
        SmartCategory.clutter.reduce(0) { $0 + $1.extras(in: analyzer).count }
    }

    /// Письма к чистке: только когда проверка почты закончена.
    private var foundMail: Int {
        mail.state == .finished ? mail.selectedCount : 0
    }

    private func startScan() {
        analyzer.scan(in: period.interval())
        mail.refresh(interval: mailPeriod.interval())
    }

    private var smartCleanCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                path.append(.smartClean)
            } label: {
                HStack(spacing: 12) {
                    ToneIcon(symbol: "wand.and.stars", tone: .violet, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Умная чистка")
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Text(smartCleanSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.smartClean")

            periodChips

            switch analyzer.state {
            case .idle:
                Button(action: startScan) {
                    Label("Найти лишнее", systemImage: "sparkles")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("home.scan")
            case let .scanning(done, total):
                VStack(alignment: .leading, spacing: 6) {
                    GradientBar(value: total == 0 ? 0 : Double(done) / Double(total))
                    Text(total == 0 ? "Подготовка…" as LocalizedStringKey : "Проанализировано \(done) из \(total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            case .finished:
                categoryChips
                // Каждая проверка — с нуля: прошлые находки и метрики не переиспользуются.
                Button(action: startScan) {
                    Label("Проверить заново", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Palette.brandEnd)
                .accessibilityIdentifier("home.rescan")
            }
        }
        .card()
    }

    private var smartCleanSubtitle: LocalizedStringKey {
        switch analyzer.state {
        case .idle: "Почта iCloud, точные копии, похожие, размытые и скриншоты"
        case .scanning: "Ищу лишнее…"
        case .finished:
            foundExtras + foundMail == 0 ? "Лишнего не нашлось" : "Найдено лишнего: \(foundExtras + foundMail)"
        }
    }

    /// За какой период ищет умная чистка: фото отдельно, почта отдельно. Нажатие открывает выбор периода,
    /// где есть и «Всё время» — тогда период не ограничен.
    private var periodChips: some View {
        HStack(spacing: 8) {
            periodChip(symbol: "photo.on.rectangle", title: "Фото: \(period.title)") { isPickingPeriod = true }
                .disabled(analyzer.isScanning)
                .accessibilityIdentifier("home.period")
            if mail.isConnected {
                periodChip(symbol: "envelope", title: "Почта: \(mailPeriod.title)") { isPickingMailPeriod = true }
                    .disabled(mail.isBusy)
                    .accessibilityIdentifier("home.mailPeriod")
            }
            Spacer(minLength: 0)
        }
    }

    private func periodChip(symbol: String, title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Palette.brandEnd)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Palette.brandEnd.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Цветные ярлыки категорий с находками: сначала почта, затем фото и видео. По нажатию открывается умная чистка.
    private var categoryChips: some View {
        let found = SmartCategory.clutter.filter { !$0.extras(in: analyzer).isEmpty }
        let letters = mail.state == .finished ? MailCategory.allCases.filter { !mail.active(in: $0).isEmpty } : []
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if mail.isScanning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                        Text("Почта: проверяю…")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Tone.blue.gradient, in: Capsule())
                }
                ForEach(letters) { category in
                    Button {
                        path.append(.smartClean)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: category.symbol)
                            Text(category.title)
                            Text("\(mail.active(in: category).count)")
                                .monospacedDigit()
                                .fontWeight(.bold)
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(category.tone.gradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(found) { category in
                    Button {
                        path.append(.smartClean)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: category.symbol)
                            Text(category.title)
                            Text("\(category.extras(in: analyzer).count)")
                                .monospacedDigit()
                                .fontWeight(.bold)
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(category.tone.gradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Свайпы

    private var unreviewed: Int {
        max(media.photos + media.videos - store.reviewedIDs.count, 0)
    }

    private var swipeCard: some View {
        Button {
            router.tab = .review
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Свайп-разбор")
                        .font(.title3.bold())
                    Text("Влево — удалить, вправо — оставить")
                        .font(.subheadline)
                        .opacity(0.9)
                    Text("Не разобрано: \(unreviewed)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .opacity(0.9)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title)
            }
            .gradientCard(Tone.orange.gradient)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.swipe")
    }

    // MARK: - Инструменты

    private var toolsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Инструменты")
                .font(.title3.bold())
                .padding(.leading, 4)
            LazyVGrid(columns: columns, spacing: 12) {
                ToolTile(title: "Сжатие", subtitle: "Фото и видео меньше", symbol: "arrow.down.right.and.arrow.up.left", tone: .green) {
                    path.append(.compress)
                }
                .accessibilityIdentifier("home.compress")
                ToolTile(title: "Секретная папка", subtitle: "PIN-код и Face ID", symbol: "lock.fill", tone: .indigo) {
                    path.append(.vault)
                }
                .accessibilityIdentifier("home.vault")
                ToolTile(title: "Контакты", subtitle: "Дубли и пустые", symbol: "person.2.fill", tone: .cyan) {
                    path.append(.contacts)
                }
                .accessibilityIdentifier("home.contacts")
                ToolTile(title: "Календарь", subtitle: "Старые события", symbol: "calendar.badge.minus", tone: .red) {
                    path.append(.calendar)
                }
                .accessibilityIdentifier("home.calendar")
                ToolTile(title: "Почта iCloud", subtitle: "Спам и рассылки", symbol: "envelope.badge.fill", tone: .blue) {
                    path.append(.mail)
                }
                .accessibilityIdentifier("home.mail")
            }
        }
    }

    private func refresh() async {
        storage = DeviceStorage.current()
        let counts = await Task.detached(priority: .userInitiated) { MediaSummary.counts() }.value
        media = MediaSummary(
            photos: counts.photos, videos: counts.videos, screenshots: counts.screenshots, livePhotos: counts.livePhotos,
            bytes: media.bytes, breakdown: media.breakdown
        )
        let full = await Task.detached(priority: .utility) { counts.withBytes() }.value
        guard !Task.isCancelled else { return }
        media = full
    }
}

/// Плитка инструмента на главной.
private struct ToolTile: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String
    let tone: Tone
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ToneIcon(symbol: symbol, tone: tone, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .card(padding: 14, radius: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
