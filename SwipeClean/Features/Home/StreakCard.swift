import SwiftData
import SwiftUI

/// Серия на главной: сколько дней подряд чистили галерею, последняя неделя кружками и ежедневное напоминание.
struct StreakCard: View {
    @Environment(ReviewStore.self) private var store
    @Environment(DailyReminder.self) private var reminder
    @Environment(TabRouter.self) private var router
    @Query(sort: \DailyStat.day) private var days: [DailyStat]
    @AppStorage(SettingsKeys.reminderEnabled) private var reminderEnabled = false
    @AppStorage(SettingsKeys.reminderMinutes) private var reminderMinutes = DailyReminder.defaultMinutes
    @State private var showDenied = false

    var body: some View {
        let active = Set(days.filter(\.isActive).map(\.day))
        let streak = StatsCalculator.streak(activeDays: active)
        let week = StatsCalculator.recentDays(7, activeDays: active)
        let cleanedToday = week.last?.isActive ?? false

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ToneIcon(symbol: "flame.fill", tone: .orange, size: 46)
                        .symbolEffect(.bounce, value: streak.current)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Серия")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(streak.current == 0
                             ? String(localized: "Начните сегодня")
                             : String(localized: "\(StatsCalculator.daysText(streak.current)) подряд"))
                            .font(.title3.bold())
                            .contentTransition(.numericText(value: Double(streak.current)))
                    }
                    Spacer(minLength: 0)
                    if streak.best > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Рекорд")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(StatsCalculator.daysText(streak.best))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                        }
                    }
                }

                weekRow(week)

                Text(status(current: streak.current, cleanedToday: cleanedToday))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("home.streak")

            reminderButton
        }
        .card()
        .animation(.snappy, value: streak.current)
        .notificationsDeniedAlert(isPresented: $showDenied)
    }

    private func status(current: Int, cleanedToday: Bool) -> LocalizedStringKey {
        if cleanedToday { return "Сегодня уже чистили — так держать!" }
        if current > 0 { return "Разберите хотя бы одно фото сегодня, чтобы не прервать серию." }
        return "Разбирайте хотя бы одно фото в день, и серия начнёт расти."
    }

    /// Неделя кружками: огонёк — день с чисткой, обводка — сегодня.
    private func weekRow(_ week: [StatsCalculator.DayMark]) -> some View {
        HStack(spacing: 0) {
            ForEach(week, id: \.day) { mark in
                VStack(spacing: 6) {
                    ZStack {
                        if mark.isActive {
                            Circle().fill(Tone.orange.gradient)
                            Image(systemName: "flame.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        } else {
                            Circle().fill(Color(.tertiarySystemFill))
                        }
                    }
                    .frame(width: 30, height: 30)
                    .overlay {
                        if mark.isToday {
                            Circle()
                                .strokeBorder(Tone.orange.color, lineWidth: 2)
                                .padding(-4)
                        }
                    }
                    Text(mark.day, format: .dateTime.weekday(.short))
                        .font(.caption2.weight(mark.isToday ? .bold : .medium))
                        .foregroundStyle(mark.isToday ? Color.primary : Color.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var reminderOn: Bool { reminderEnabled && reminder.isAuthorized }

    /// Включённое напоминание ведёт в Настройки (там время), выключенное включается прямо отсюда.
    private var reminderButton: some View {
        Button {
            if reminderOn {
                router.tab = .settings
            } else {
                Task {
                    let enabled = await reminder.enable(store: store)
                    if !enabled { showDenied = true }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: reminderOn ? "bell.fill" : "bell.badge")
                Text(reminderOn
                     ? String(localized: "Напоминание в \(DailyReminder.timeText(minutes: reminderMinutes))")
                     : String(localized: "Напоминать каждый день"))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .opacity(0.6)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Tone.orange.color)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tone.orange.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.reminder")
    }
}

/// Похвала в стопке за первую чистку дня: серия началась или выросла.
struct StreakToast: View {
    let days: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "flame.fill")
                .font(.title3)
                .symbolEffect(.bounce, value: days)
            VStack(alignment: .leading, spacing: 1) {
                Text(days <= 1 ? "Серия началась" as LocalizedStringKey : "Серия продлена")
                    .font(.headline)
                Text(String(localized: "\(StatsCalculator.daysText(days)) подряд"))
                    .font(.caption)
                    .opacity(0.9)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Tone.red.gradient, in: Capsule())
        .shadow(color: Tone.red.color.opacity(0.45), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("deck.streak")
    }
}
