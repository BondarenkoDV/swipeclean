import SwiftUI

struct RootView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKeys.onboardingCompleted) private var onboardingCompleted = false
    @AppStorage(SettingsKeys.appearance) private var appearance = AppAppearance.system

    var body: some View {
        Group {
            if onboardingCompleted && library.hasAccess {
                MainTabView()
            } else {
                // После онбординга сюда попадают, только если доступ отозвали: сразу открываем страницу доступа.
                OnboardingView(startsAtAccessPage: onboardingCompleted) {
                    onboardingCompleted = true
                }
            }
        }
        .animation(.default, value: library.hasAccess)
        .preferredColorScheme(appearance.colorScheme)
        // Доступ могли поменять в Настройках, пока приложение было в фоне.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refreshStatus() }
        }
    }
}

/// Вкладки приложения.
enum AppTab: Hashable {
    case home
    case review
    case trash
    case stats
    case settings
}

/// Какая вкладка открыта: главная переключает на «Разбор» по кнопке свайпов.
@MainActor
@Observable
final class TabRouter {
    var tab: AppTab = .home
}

struct MainTabView: View {
    @Environment(ReviewStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var fullScreen = FullScreenPresenter()
    @State private var router = TabRouter()
    /// Анализ умной чистки общий: главная показывает его прогресс, экран умной чистки — результаты.
    @State private var analyzer = SmartCleanAnalyzer()
    @State private var vault = VaultStore()
    /// Почта тоже общая: проверка ящика переживает уход с экрана, а найденное не ищется заново.
    @State private var mail = MailCleaner()

    var body: some View {
        TabView(selection: Bindable(router).tab) {
            HomeView()
                .tabItem { Label("Главная", systemImage: "sparkles") }
                .tag(AppTab.home)
            ReviewHomeView()
                .tabItem { Label("Разбор", systemImage: "rectangle.stack") }
                .tag(AppTab.review)
            TrashView()
                .tabItem { Label("Корзина", systemImage: "trash") }
                .badge(store.trashCount)
                .tag(AppTab.trash)
            StatsView()
                .tabItem { Label("Статистика", systemImage: "chart.bar") }
                .tag(AppTab.stats)
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .environment(fullScreen)
        .environment(router)
        .environment(analyzer)
        .environment(vault)
        .environment(mail)
        .overlay {
            if let peek = fullScreen.peek {
                PeekView(asset: peek)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.snappy(duration: 0.2), value: fullScreen.peek)
        .fullScreenCover(item: Bindable(fullScreen).asset) { asset in
            FullScreenAssetView(asset: asset)
        }
        // Секретная папка закрывается, когда приложение уходит в фон. Не при .inactive: туда же попадают
        // системные окна (Face ID, подтверждение удаления), и папка закрывалась бы посреди работы.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { vault.lock() }
        }
    }
}
