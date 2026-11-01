import Photos
import SwiftUI

/// Умная чистка. Сначала почта iCloud и Gmail (спам, рассылки, старые письма), затем точные копии фото и видео:
/// их можно убрать одной кнопкой. Похожие кадры, серии, размытые фото и старые скриншоты открываются по плиткам.
/// Тяжёлые видео только показываются: общая кнопка их не трогает, удалять или нет, решает пользователь.
/// Анализатор и почта общие на всё приложение: главная показывает их прогресс и итог.
struct SmartCleanView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(SmartCleanAnalyzer.self) private var analyzer
    @Environment(ReviewStore.self) private var store
    @Environment(MailCleaner.self) private var mail
    @AppStorage(SettingsKeys.smartCleanPeriod) private var period = SmartCleanPeriod.all
    @AppStorage(SettingsKeys.mailPeriod) private var mailPeriod = SmartCleanPeriod.all
    @State private var isPickingPeriod = false
    @State private var isPickingMailPeriod = false
    @State private var bytes: [SmartCategory: Int64] = [:]
    @State private var confirmClean = false

    private var interval: DateInterval? {
        period.interval()
    }

    private var mailInterval: DateInterval? {
        mailPeriod.interval()
    }

    /// Точные копии фото и видео: их можно убрать одним нажатием без риска потерять нужный кадр.
    private var duplicateExtras: [PHAsset] {
        guard analyzer.state == .finished else { return [] }
        return SmartCategory.duplicates.extras(in: analyzer) + SmartCategory.videoDuplicates.extras(in: analyzer)
    }

    /// Письма, которые уйдут по общей кнопке: только когда проверка почты закончена.
    private var mailCount: Int {
        mail.state == .finished ? mail.selectedCount : 0
    }

    private var canClean: Bool {
        !mail.isBusy && !analyzer.isScanning && (mailCount > 0 || !duplicateExtras.isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                scanCard
                mailCard
                if canClean {
                    cleanButton
                }
                periodRow
                if analyzer.state == .finished {
                    // Обычная, не ленивая сетка: плиток всего восемь, и все они должны существовать сразу,
                    // даже ниже края экрана под карточкой почты. Почта — первая плитка, как и остальные категории.
                    VStack(spacing: 12) {
                        ForEach(Array(SmartTile.all.chunks(of: 2).enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 12) {
                                ForEach(row) { tile in
                                    tileLink(tile)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .screenBackground()
        .navigationTitle("Умная чистка")
        .onChange(of: period) { analyzer.reset() }
        .onChange(of: mailPeriod) { mail.scanIfNeeded(interval: mailInterval) }
        // Фото удалили через корзину или в другом приложении: убираем их из найденного, а не показываем пустые клетки.
        .onChange(of: library.changeCount) { _, _ in Task { await analyzer.dropMissing() } }
        .task(id: resultKey) { await updateBytes() }
        .sheet(isPresented: $isPickingPeriod) {
            PeriodPickerView(selection: $period)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $isPickingMailPeriod) {
            PeriodPickerView(selection: $mailPeriod)
                .presentationDetents([.large])
        }
        .confirmationDialog("Очистить лишнее?", isPresented: $confirmClean, titleVisibility: .visible) {
            Button("Очистить", role: .destructive, action: cleanAll)
                .accessibilityIdentifier("smart.confirmClean")
        } message: {
            Text(confirmMessage)
        }
    }

    /// Сколько займёт лишнее среди фото и видео. Тяжёлые видео сюда не входят: это не мусор.
    private var clutterBytes: Int64 {
        SmartCategory.clutter.reduce(0) { $0 + (bytes[$1] ?? 0) }
    }

    /// Меняется, когда меняется состав найденного: тогда размеры пересчитываются.
    private var resultKey: [Int] {
        SmartCategory.allCases.map { $0.extras(in: analyzer).count } + [analyzer.state == .finished ? 1 : 0]
    }

    private func startScan() {
        analyzer.scan(in: interval)
        mail.refresh(interval: mailInterval)
    }

    // MARK: - Анализ

    @ViewBuilder
    private var scanCard: some View {
        switch analyzer.state {
        case .idle:
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ToneIcon(symbol: "wand.and.stars", tone: .violet, size: 44)
                    Text("Проверю почту и найду точные копии фото и видео, похожие кадры, серии, размытые фото и старые скриншоты. Тяжёлые видео только покажу: удалять их или нет, решаете вы. Фото анализируются только на устройстве.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button("Начать анализ", action: startScan)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("smart.scan")
            }
            .card()
        case let .scanning(done, total):
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ToneIcon(symbol: "sparkle.magnifyingglass", tone: .violet, size: 36)
                    Text("Анализ медиатеки")
                        .font(.headline)
                    Spacer()
                    Button("Отмена") { analyzer.cancel() }
                        .font(.subheadline)
                }
                GradientBar(value: total == 0 ? 0 : Double(done) / Double(total))
                Text(total == 0 ? "Подготовка…" as LocalizedStringKey : "Проанализировано \(done) из \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .card()
        case .finished:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ToneIcon(symbol: "checkmark.seal.fill", tone: .green, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Можно освободить")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(bytes.isEmpty ? "…" : (clutterBytes + (mail.state == .finished ? mail.selectedBytes : 0)).formattedBytes)
                            .font(.title2.bold().monospacedDigit())
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    Button("Проверить заново", systemImage: "arrow.clockwise", action: startScan)
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .accessibilityIdentifier("smart.rescan")
                }
                if analyzer.unavailable > 0 {
                    Text("\(analyzer.unavailable) фото не проверены: оригиналы только в iCloud. Откройте их в приложении Фото, чтобы они загрузились, и проверьте заново.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .card()
        }
    }

    // MARK: - Плитки

    @ViewBuilder
    private func tileLink(_ tile: SmartTile) -> some View {
        switch tile {
        case .mail:
            NavigationLink {
                MailCleanView()
            } label: {
                CategoryTile(
                    title: "Почта",
                    symbol: "envelope.fill",
                    tone: .blue,
                    detail: Text(mailTileDetail),
                    bytes: mail.state == .finished ? mail.selectedBytes : nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("smart.mailTile")
        case let .photos(category):
            NavigationLink {
                category.destination(analyzer: analyzer)
            } label: {
                CategoryTile(
                    title: category.title,
                    symbol: category.symbol,
                    tone: category.tone,
                    detail: Text(verbatim: category.detail(in: analyzer)),
                    bytes: bytes[category],
                    hint: category.isManualOnly ? "Только вручную" : nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("smart.\(category.rawValue)")
        }
    }

    private var mailTileDetail: LocalizedStringKey {
        guard mail.isConnected else { return "Подключить" }
        switch mail.state {
        case .connecting, .scanning: return "Проверяю письма…"
        case .cleaning: return "Удаляю письма…"
        case .finished: return "Писем: \(mail.selectedCount)"
        case .idle: return "Проверить почту"
        }
    }

    // MARK: - Почта

    @ViewBuilder
    private var mailCard: some View {
        if mail.isConnected {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink {
                    MailCleanView()
                } label: {
                    HStack(spacing: 12) {
                        ToneIcon(symbol: "envelope.fill", tone: .blue, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: mail.accountsTitle)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(mailStatus)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("smart.mailDetails")

                mailPeriodRow
                mailProgress
                if mail.state == .finished || mail.hasFindings {
                    ForEach(MailCategory.allCases) { category in
                        if !mail.messages(in: category).isEmpty {
                            mailCategoryRow(category)
                        }
                    }
                }
                if let report = mail.report {
                    Label(report.summary, systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Tone.green.color)
                        .accessibilityIdentifier("smart.mailReport")
                }
                // Ошибка показывается здесь же, а не окном: экран почты поверх этого показывает своё окно.
                if let message = mail.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Tone.red.color)
                        .accessibilityIdentifier("smart.mailError")
                }
                if mail.state == .idle, !mail.hasFindings {
                    Button("Проверить почту") { mail.refresh(interval: mailInterval) }
                        .buttonStyle(PrimaryButtonStyle(gradient: Tone.blue.gradient))
                        .accessibilityIdentifier("smart.mailScan")
                }
            }
            .card()
        } else {
            NavigationLink {
                MailCleanView()
            } label: {
                HStack(spacing: 12) {
                    ToneIcon(symbol: "envelope.badge.fill", tone: .blue, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Почта")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Подключите iCloud Mail или Gmail, чтобы умная чистка убирала спам и рассылки")
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
                .card(padding: 14)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("smart.mailConnect")
        }
    }

    private var mailStatus: LocalizedStringKey {
        switch mail.state {
        case .connecting: "Подключаюсь к почте…"
        case .scanning: "Проверяю письма…"
        case .cleaning: "Удаляю письма…"
        case .finished: mail.selectedCount > 0 ? "К чистке писем: \(mail.selectedCount)" : "Лишних писем нет"
        case .idle: "Проверится вместе с фото"
        }
    }

    private var mailPeriodRow: some View {
        Button {
            isPickingMailPeriod = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .foregroundStyle(Tone.indigo.color)
                Text("Период писем")
                    .foregroundStyle(.primary)
                Spacer()
                Text(mailPeriod.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.brandEnd)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(mail.isBusy)
        .accessibilityIdentifier("smart.mailPeriod")
    }

    @ViewBuilder
    private var mailProgress: some View {
        switch mail.state {
        case let .scanning(done, total):
            VStack(alignment: .leading, spacing: 6) {
                GradientBar(value: total == 0 ? 0 : Double(done) / Double(total), gradient: Tone.blue.gradient)
                Text(total == 0 ? "Подключаюсь к почте…" as LocalizedStringKey : "Проверено \(done) из \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case let .cleaning(done, total):
            VStack(alignment: .leading, spacing: 6) {
                GradientBar(value: total == 0 ? 0 : Double(done) / Double(total), gradient: Tone.blue.gradient)
                Text("Удалено \(done) из \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .connecting:
            ProgressView()
                .frame(maxWidth: .infinity)
        case .idle, .finished:
            EmptyView()
        }
    }

    /// Строка категории писем: нажатие включает её в общую чистку или выключает.
    private func mailCategoryRow(_ category: MailCategory) -> some View {
        let isOn = mail.selected.contains(category)
        return Button {
            mail.setSelected(category, !isOn)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? category.tone.color : Color(.tertiaryLabel))
                ToneIcon(symbol: category.symbol, tone: category.tone, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Писем: \(mail.active(in: category).count) · \(mail.bytes(in: category).formattedBytes)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(mail.isBusy)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("smart.mail.\(category.rawValue)")
    }

    // MARK: - Одна кнопка

    private var cleanTitle: LocalizedStringKey {
        let copies = duplicateExtras.count
        if mailCount > 0, copies > 0 {
            return "Очистить: писем \(mailCount), копий \(copies)"
        }
        if mailCount > 0 {
            return "Очистить почту (\(mailCount))"
        }
        return "Все копии в корзину (\(copies))"
    }

    private var cleanButton: some View {
        Button {
            confirmClean = true
        } label: {
            Label(cleanTitle, systemImage: "sparkles")
        }
        .buttonStyle(PrimaryButtonStyle())
        .accessibilityIdentifier("smart.clean")
    }

    private var confirmMessage: String {
        var parts: [String] = []
        if mailCount > 0 {
            let movable = mail.selectedMovableCount
            parts.append(String(localized: "Писем навсегда из «Спама» и «Удалённых»: \(mailCount - movable), в корзину почты: \(movable)."))
        }
        if !duplicateExtras.isEmpty {
            parts.append(String(localized: "Копий фото и видео в корзину приложения: \(duplicateExtras.count), в каждой группе останется лучший экземпляр."))
        }
        return parts.joined(separator: " ")
    }

    private func cleanAll() {
        if !duplicateExtras.isEmpty {
            trashDuplicates()
        }
        if mailCount > 0 {
            Task { await mail.clean() }
        }
    }

    // MARK: - Фото и видео

    private var periodRow: some View {
        Button {
            isPickingPeriod = true
        } label: {
            HStack(spacing: 12) {
                ToneIcon(symbol: "calendar", tone: .indigo, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Период")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Все категории ищут только среди фото и видео, снятых в выбранный период.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Text(period.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.brandEnd)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .card(padding: 14)
        }
        .buttonStyle(.plain)
        .disabled(analyzer.isScanning)
        .accessibilityIdentifier("smart.period")
    }

    private func trashDuplicates() {
        let groups = SmartCategory.duplicates.groups(in: analyzer) + SmartCategory.videoDuplicates.groups(in: analyzer)
        var decisions: [ReviewStore.Decision] = []
        for group in groups {
            for asset in group.assets {
                decisions.append(ReviewStore.Decision(asset, group.keepIDs.contains(asset.localIdentifier) ? .keep : .trash))
            }
        }
        store.record(decisions)
        analyzer.removeHandled(Set(groups.flatMap { $0.assets.map(\.localIdentifier) }))
    }

    private func updateBytes() async {
        guard analyzer.state == .finished else {
            bytes = [:]
            return
        }
        var extras: [SmartCategory: [PHAsset]] = [:]
        for category in SmartCategory.allCases {
            extras[category] = category.extras(in: analyzer)
        }
        let result = await SmartCategory.extraBytes(extras)
        guard !Task.isCancelled else { return }
        withAnimation { bytes = result }
    }
}

/// Плитка умной чистки: почта или категория фото и видео.
private enum SmartTile: Identifiable {
    case mail
    case photos(SmartCategory)

    static let all: [SmartTile] = [.mail] + SmartCategory.allCases.map { .photos($0) }

    var id: String {
        switch self {
        case .mail: "mail"
        case let .photos(category): category.rawValue
        }
    }
}

/// Цветная плитка категории: значок, название, сколько найдено и сколько места это занимает.
private struct CategoryTile: View {
    let title: LocalizedStringKey
    let symbol: String
    let tone: Tone
    let detail: Text
    let bytes: Int64?
    var hint: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ToneIcon(symbol: symbol, tone: tone, size: 38)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                if let hint {
                    Text(hint)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tone.color)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                detail
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let bytes, bytes > 0 {
                    Text(bytes.formattedBytes)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(tone.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(tone.color.opacity(0.14), in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .card(padding: 14, radius: 20)
    }
}
