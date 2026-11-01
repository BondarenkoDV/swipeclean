import Photos
import SwiftUI
import UIKit
import UserNotifications

/// Что и когда напомнить. Чистые функции, чтобы план можно было проверить тестами.
enum ReminderPlanner {
    /// На сколько дней вперёд ставятся напоминания. Каждый запуск приложения пересобирает план,
    /// так что две недели — это запас на случай, если приложение долго не открывали.
    static let horizon = 14
    static let genericVariants = 3

    enum Kind: Equatable {
        /// В этот день в прошлые годы снято столько ещё не разобранных фото; серия, если она под угрозой.
        case onThisDay(count: Int, streak: Int?)
        /// Серия прервётся, если в этот день ничего не разобрать.
        case streak(Int)
        /// Обычное напоминание. Текст меняется по дням, чтобы не приедаться.
        case generic(variant: Int)
    }

    /// Время напоминаний на ближайшие дни. Сегодняшнее пропускается, если его время прошло
    /// или сегодня уже чистили.
    static func fireDates(
        now: Date,
        minutes: Int,
        activeToday: Bool,
        days: Int = horizon,
        calendar: Calendar = .current
    ) -> [Date] {
        let today = calendar.startOfDay(for: now)
        let hour = min(max(minutes / 60, 0), 23)
        let minute = min(max(minutes % 60, 0), 59)
        return (0..<max(days, 0)).compactMap { offset -> Date? in
            if offset == 0 && activeToday { return nil }
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  fire > now else { return nil }
            return fire
        }
    }

    /// О чём напоминание в этот день.
    /// Серия упоминается, только пока она жива: сегодня — если сегодня ещё не чистили, завтра — если сегодня уже чистили.
    /// Дальше серия к тому дню уже прервётся (иначе приложение открыли бы и план пересобрался).
    static func kind(
        for fireDate: Date,
        now: Date,
        activeToday: Bool,
        streak: Int,
        onThisDay: Int,
        calendar: Calendar = .current
    ) -> Kind {
        let offset = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: fireDate)
        ).day ?? 0
        let atRisk: Int?
        switch offset {
        case 0 where !activeToday && streak > 0: atRisk = streak
        case 1 where activeToday && streak > 0: atRisk = streak
        default: atRisk = nil
        }
        if onThisDay > 0 { return .onThisDay(count: onThisDay, streak: atRisk) }
        if let atRisk { return .streak(atRisk) }
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: fireDate) ?? 0
        return .generic(variant: dayOfYear % genericVariants)
    }
}

extension ReminderPlanner.Kind {
    static let onThisDaySource = "onThisDay"
    static let reviewSource = "review"

    /// Что открыть по нажатию: подборку «В этот день» или просто разбор.
    var source: String {
        if case .onThisDay = self { return Self.onThisDaySource }
        return Self.reviewSource
    }

    var title: String {
        switch self {
        case let .onThisDay(count, _):
            String(localized: "В этот день: \(count) фото")
        case let .streak(days):
            String(localized: "Серия \(StatsCalculator.daysText(days)) 🔥")
        case let .generic(variant):
            switch variant % ReminderPlanner.genericVariants {
            case 0: String(localized: "Пара минут на чистку")
            case 1: String(localized: "Освободите немного места")
            default: String(localized: "Галерея ждёт")
            }
        }
    }

    var body: String {
        switch self {
        case let .onThisDay(_, streak?):
            String(localized: "Серия \(StatsCalculator.daysText(streak)) — разберите пару фото сегодня, чтобы её не прервать.")
        case .onThisDay:
            String(localized: "Вспомните, как это было, и уберите лишнее за пару минут.")
        case .streak:
            String(localized: "Разберите хотя бы одно фото сегодня, чтобы не прервать серию.")
        case let .generic(variant):
            switch variant % ReminderPlanner.genericVariants {
            case 0: String(localized: "Свайпните несколько фото: влево — удалить, вправо — оставить.")
            case 1: String(localized: "Каждый свайп влево — минус лишний кадр в галерее.")
            default: String(localized: "Начните серию: разберите хотя бы одно фото сегодня.")
            }
        }
    }
}

/// Одно запланированное напоминание, уже с текстом.
struct PlannedReminder: Equatable, Sendable {
    let id: String
    let date: Date
    let title: String
    let body: String
    let source: String
}

/// Ближайшее напоминание из тех, что стоят в системе: его показывают Настройки.
struct UpcomingReminder: Equatable, Sendable {
    let date: Date
    let title: String
}

/// Ежедневное напоминание о чистке: локальные уведомления на две недели вперёд, каждое со своим текстом.
///
/// Одно повторяющееся уведомление не подходит: текст у него один на все дни, а здесь он зависит от даты
/// («В этот день: 23 фото») и от серии. План пересобирается при каждом возвращении в приложение,
/// после первой чистки за день (сегодняшнее напоминание тогда уже не нужно) и при смене настроек.
@MainActor
@Observable
final class DailyReminder {
    static let shared = DailyReminder()
    nonisolated static let identifierPrefix = "daily-reminder."
    nonisolated static let defaultMinutes = 20 * 60

    /// Просьба открыть разбор после нажатия на напоминание. `id` нужен, чтобы два одинаковых нажатия различались.
    struct OpenRequest: Equatable {
        let id = UUID()
        let source: LibrarySource?
    }

    private(set) var status: UNAuthorizationStatus = .notDetermined
    /// Ближайшее напоминание, которое действительно стоит в системе.
    private(set) var upcoming: UpcomingReminder?
    var openRequest: OpenRequest?

    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var lastApplied: Snapshot?

    private init() {}

    var isAuthorized: Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.reminderEnabled)
    }

    var minutes: Int {
        UserDefaults.standard.object(forKey: SettingsKeys.reminderMinutes) as? Int ?? Self.defaultMinutes
    }

    /// «20:00» в формате системы.
    nonisolated static func timeText(minutes: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    func refreshStatus() async {
        status = await Self.authorizationStatus()
    }

    /// Включает напоминание. Системный запрос разрешения показывается только в первый раз;
    /// если уведомления запрещены, возвращает false, и экран предлагает открыть Настройки.
    func enable(store: ReviewStore) async -> Bool {
        _ = await Self.requestAuthorization()
        await refreshStatus()
        guard isAuthorized else { return false }
        UserDefaults.standard.set(true, forKey: SettingsKeys.reminderEnabled)
        reschedule(store: store)
        return true
    }

    func disable(store: ReviewStore) {
        UserDefaults.standard.set(false, forKey: SettingsKeys.reminderEnabled)
        reschedule(store: store)
    }

    func open(source: String?) {
        openRequest = OpenRequest(source: source == ReminderPlanner.Kind.onThisDaySource ? .onThisDay : nil)
    }

    /// Пересобирает план. Вызовы выполняются по очереди: иначе старый план мог бы лечь в систему поверх нового.
    func reschedule(store: ReviewStore) {
        let input = Input(
            enabled: isEnabled,
            minutes: minutes,
            activeToday: store.isActiveToday,
            streak: store.streak().current,
            reviewed: store.reviewedIDs,
            protection: ProtectionPolicy.current
        )
        let previous = queue
        queue = Task {
            await previous?.value
            await apply(input)
        }
    }

    private struct Input {
        let enabled: Bool
        let minutes: Int
        let activeToday: Bool
        let streak: Int
        let reviewed: Set<String>
        let protection: ProtectionPolicy
    }

    /// То, от чего зависит план. Если ничего не поменялось, уведомления не пересоздаются.
    private struct Snapshot: Equatable {
        let authorized: Bool
        let enabled: Bool
        let activeToday: Bool
        let streak: Int
        let reviewedCount: Int
        let protection: ProtectionPolicy
        let dates: [Date]
    }

    private func apply(_ input: Input) async {
        await refreshStatus()
        let now = Date.now
        let active = input.enabled && isAuthorized
        let dates = active
            ? ReminderPlanner.fireDates(now: now, minutes: input.minutes, activeToday: input.activeToday)
            : []
        let snapshot = Snapshot(
            authorized: isAuthorized, enabled: input.enabled, activeToday: input.activeToday,
            streak: input.streak, reviewedCount: input.reviewed.count, protection: input.protection, dates: dates
        )
        guard snapshot != lastApplied else { return }
        lastApplied = snapshot
        let activeToday = input.activeToday
        let streak = input.streak
        let reviewed = input.reviewed
        let protection = input.protection
        let reminders = await Task.detached(priority: .utility) {
            Self.plan(
                dates: dates, now: now, activeToday: activeToday, streak: streak,
                reviewed: reviewed, protection: protection
            )
        }.value
        upcoming = await Self.replacePending(with: reminders)
    }

    /// Тексты на каждый день. Число фото «В этот день» считается запросами к медиатеке, поэтому вне главного потока.
    nonisolated static func plan(
        dates: [Date],
        now: Date,
        activeToday: Bool,
        streak: Int,
        reviewed: Set<String>,
        protection: ProtectionPolicy = .nothing,
        calendar: Calendar = .current
    ) -> [PlannedReminder] {
        guard !dates.isEmpty else { return [] }
        let oldest = LibraryFetcher.oldestYear(calendar: calendar)
        return dates.map { date in
            let count = oldest.map { year in
                LibraryFetcher.onThisDayIDs(for: date, since: year, excluding: protection, calendar: calendar)
                    .filter { !reviewed.contains($0) }
                    .count
            } ?? 0
            let kind = ReminderPlanner.kind(
                for: date, now: now, activeToday: activeToday, streak: streak, onThisDay: count, calendar: calendar
            )
            let day = calendar.dateComponents([.year, .month, .day], from: date)
            return PlannedReminder(
                id: identifierPrefix + "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)",
                date: date,
                title: kind.title,
                body: kind.body,
                source: kind.source
            )
        }
    }

    // MARK: - Системные уведомления

    nonisolated private static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    nonisolated private static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Убирает прежние напоминания, ставит новые и возвращает ближайшее из тех, что реально стоят в системе.
    nonisolated private static func replacePending(with reminders: [PlannedReminder]) async -> UpcomingReminder? {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: old)

        let calendar = Calendar.current
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.threadIdentifier = "daily-reminder"
            content.userInfo = ["source": reminder.source]
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }

        return await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(identifierPrefix) }
            .compactMap { request -> UpcomingReminder? in
                guard let date = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() else { return nil }
                return UpcomingReminder(date: date, title: request.content.title)
            }
            .min { $0.date < $1.date }
    }
}

/// Нажатие на напоминание открывает разбор, а если в нём были воспоминания — подборку «В этот день».
/// Назначается делегатом при запуске, чтобы нажатие не потерялось, даже если приложение было закрыто.
final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = ReminderNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        if request.identifier.hasPrefix(DailyReminder.identifierPrefix) {
            let source = request.content.userInfo["source"] as? String
            Task { @MainActor in
                DailyReminder.shared.open(source: source)
            }
        }
        completionHandler()
    }
}

extension View {
    /// Окно «Уведомления выключены» с переходом в настройки уведомлений приложения.
    func notificationsDeniedAlert(isPresented: Binding<Bool>) -> some View {
        alert("Уведомления выключены", isPresented: isPresented) {
            Button("Открыть Настройки") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Разрешите уведомления для SwipeClean в Настройках iOS, чтобы получать напоминание.")
        }
    }
}

extension Date {
    /// «Завтра, 20:00»: день словами, если он рядом.
    var relativeDayAndTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: self)
    }
}
