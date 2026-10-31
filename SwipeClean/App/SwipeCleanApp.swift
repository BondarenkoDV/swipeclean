import AVFoundation
import SwiftData
import SwiftUI

@main
struct SwipeCleanApp: App {
    private let container: ModelContainer
    @State private var library = PhotoLibraryService()
    @State private var store: ReviewStore
    @State private var storeIssue: StoreIssue?

    /// Запуск из UI-тестов: каждый запуск начинается с чистого листа и не трогает настоящий прогресс.
    /// В Release-сборке переключателя нет: тестовые данные и поддельная почта туда не попадают.
    #if DEBUG
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")
    #else
    static let isUITesting = false
    #endif

    init() {
        // Видео на карточках не должны обрывать музыку из других приложений.
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        if Self.isUITesting, let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }

        let (container, issue) = Self.makeContainer()
        self.container = container
        _store = State(initialValue: ReviewStore(context: container.mainContext))
        _storeIssue = State(initialValue: issue)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(store)
                .alert(
                    storeIssue?.title ?? "",
                    isPresented: Binding(get: { storeIssue != nil }, set: { if !$0 { storeIssue = nil } })
                ) {
                    Button("OK") { storeIssue = nil }
                } message: {
                    Text(storeIssue?.message ?? "")
                }
        }
        .modelContainer(container)
    }

    /// Что пошло не так с хранилищем при запуске.
    enum StoreIssue {
        /// Файл был повреждён: его отложили в сторону и начали с чистого хранилища.
        case reset
        /// Хранилище не открылось даже заново: работаем в памяти до перезапуска.
        case inMemory

        var title: String {
            switch self {
            case .reset: String(localized: "Прогресс сброшен")
            case .inMemory: String(localized: "Прогресс не сохраняется")
            }
        }

        var message: String {
            switch self {
            case .reset:
                String(localized: "Файл с решениями был повреждён, поэтому начали заново. Фото в медиатеке не тронуты.")
            case .inMemory:
                String(localized: "Не удалось открыть хранилище. Решения будут работать до закрытия приложения. Фото в медиатеке не тронуты.")
            }
        }
    }

    /// Открывает хранилище, а если файл повреждён, откладывает его и создаёт новое вместо падения приложения.
    private static func makeContainer() -> (ModelContainer, StoreIssue?) {
        let schema = Schema([ReviewedAsset.self, DailyStat.self, PinnedAlbum.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isUITesting)
        if let container = try? ModelContainer(for: schema, configurations: configuration) {
            return (container, nil)
        }
        moveAside(configuration.url)
        if let container = try? ModelContainer(for: schema, configurations: configuration) {
            return (container, .reset)
        }
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // В памяти контейнер открывается всегда; если и это не вышло, дальше работать нечем.
        guard let container = try? ModelContainer(for: schema, configurations: memory) else {
            fatalError("SwiftData недоступна")
        }
        return (container, .inMemory)
    }

    /// Переименовывает файл хранилища и его спутники (-wal, -shm), чтобы не потерять их совсем.
    private static func moveAside(_ url: URL) {
        let manager = FileManager.default
        let stamp = Int(Date.now.timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            let target = URL(fileURLWithPath: url.path + ".corrupt-\(stamp)" + suffix)
            try? manager.moveItem(at: source, to: target)
        }
    }
}
