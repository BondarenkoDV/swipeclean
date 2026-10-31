import SwiftUI

/// Календарь периода: сетка месяцев, кварталов или лет с переключением года.
/// Первый тап выбирает ячейку, второй растягивает выбор до диапазона между ними.
struct PeriodPickerView: View {
    @Binding var selection: SmartCleanPeriod
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case month, quarter, year
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .month: "Месяц"
            case .quarter: "Квартал"
            case .year: "Год"
            }
        }
    }

    @State private var mode: Mode = .month
    @State private var year = Calendar.current.component(.year, from: .now)
    /// Последний год страницы в режиме «Год»: страница показывает 12 лет.
    @State private var yearPageEnd = Calendar.current.component(.year, from: .now)
    /// Начало диапазона, ждущее второго тапа.
    @State private var anchor: SmartCleanPeriod?

    private let currentYear = Calendar.current.component(.year, from: .now)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("Режим", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if mode == .year {
                        yearPageSwitcher
                    } else {
                        yearSwitcher
                    }

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(cells, id: \.self) { period in
                            cell(period)
                        }
                    }

                    VStack(spacing: 4) {
                        Text(selection.title)
                            .font(.headline)
                        Text(anchor == nil ? "Нажми на месяц, а потом на последний месяц диапазона" : "Теперь нажми, где диапазон заканчивается")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        selection = .all
                        anchor = nil
                    } label: {
                        Label("Всё время", systemImage: "infinity")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(selection == .all ? .accentColor : .secondary)
                }
                .padding()
            }
            .navigationTitle("Период")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .onAppear(perform: syncWithSelection)
        }
    }

    private var yearSwitcher: some View {
        HStack {
            Button("Предыдущий год", systemImage: "chevron.left") { year -= 1 }
                .labelStyle(.iconOnly)
            Spacer()
            Text(String(year))
                .font(.title3.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
            Spacer()
            Button("Следующий год", systemImage: "chevron.right") { year += 1 }
                .labelStyle(.iconOnly)
                .disabled(year >= currentYear)
        }
        .font(.title3)
        .animation(.snappy, value: year)
    }

    /// Листает годы страницами по 12, чтобы можно было дойти до самых старых фото.
    private var yearPageSwitcher: some View {
        HStack {
            Button("Предыдущие годы", systemImage: "chevron.left") { yearPageEnd -= 12 }
                .labelStyle(.iconOnly)
            Spacer()
            Text(verbatim: "\(yearPageEnd - 11)–\(yearPageEnd)")
                .font(.title3.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
            Spacer()
            Button("Следующие годы", systemImage: "chevron.right") { yearPageEnd = min(currentYear, yearPageEnd + 12) }
                .labelStyle(.iconOnly)
                .disabled(yearPageEnd >= currentYear)
        }
        .font(.title3)
        .animation(.snappy, value: yearPageEnd)
    }

    private var cells: [SmartCleanPeriod] {
        switch mode {
        case .month: (1...12).map { .month(year: year, month: $0) }
        case .quarter: (1...4).map { .quarter(year: year, quarter: $0) }
        case .year: (0..<12).map { .year(yearPageEnd - 11 + $0) }
        }
    }

    private func cell(_ period: SmartCleanPeriod) -> some View {
        let isSelected = selection != .all && selection.contains(period)
        return Button {
            tap(period)
        } label: {
            Text(label(for: period))
                .font(.body.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.tertiary),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("period.cell")
        .disabled(period.isFuture())
        .opacity(period.isFuture() ? 0.35 : 1)
    }

    private func label(for period: SmartCleanPeriod) -> String {
        switch period {
        case .all:
            return period.title
        case let .months(from, _):
            switch mode {
            case .month:
                let date = Calendar.current.date(from: DateComponents(year: from.year, month: from.month, day: 1)) ?? .now
                return date.formatted(.dateTime.month(.abbreviated)).capitalized
            case .quarter:
                return String(localized: "\((from.month - 1) / 3 + 1) кв.")
            case .year:
                return String(from.year)
            }
        }
    }

    private func tap(_ period: SmartCleanPeriod) {
        if let anchor {
            selection = anchor.spanning(period)
            self.anchor = nil
        } else {
            selection = period
            anchor = period
        }
    }

    /// Открывает календарь на режиме и годе текущего выбора.
    private func syncWithSelection() {
        if case let .months(from, through) = selection {
            year = through.year
            yearPageEnd = currentYear - max(0, currentYear - through.year) / 12 * 12
            if from.year != through.year, from.month == 1, through.month == 12 {
                mode = .year
            } else if from.month == 1, through.month == 12 {
                mode = .month
            } else if (from.month - 1) % 3 == 0, through.month % 3 == 0, from != through {
                mode = .quarter
            } else {
                mode = .month
            }
        }
    }
}
