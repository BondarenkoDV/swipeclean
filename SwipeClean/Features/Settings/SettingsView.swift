import SwiftUI

struct SettingsView: View {
    @Environment(ReviewStore.self) private var store
    @Environment(PhotoLibraryService.self) private var library

    @AppStorage(SettingsKeys.swapHorizontalSwipes) private var swapHorizontal = false
    @AppStorage(SettingsKeys.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(SettingsKeys.videoSoundEnabled) private var videoSoundEnabled = false
    @AppStorage(SettingsKeys.appearance) private var appearance = AppAppearance.system

    @State private var showAlbums = false
    @State private var confirmReset = false
    @State private var cacheCleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $swapHorizontal) {
                        SettingsLabel("Поменять влево и вправо", symbol: "arrow.left.arrow.right", tone: .blue)
                    }
                    LabeledContent {
                        Text(swapHorizontal ? String(localized: "Оставить") : String(localized: "В корзину"))
                    } label: {
                        SettingsLabel("Влево", gesture: .left, tone: swapHorizontal ? .green : .red)
                    }
                    LabeledContent {
                        Text(swapHorizontal ? String(localized: "В корзину") : String(localized: "Оставить"))
                    } label: {
                        SettingsLabel("Вправо", gesture: .right, tone: swapHorizontal ? .red : .green)
                    }
                    LabeledContent {
                        Text("В избранное")
                    } label: {
                        SettingsLabel("Вверх", gesture: .up, tone: .yellow)
                    }
                    LabeledContent {
                        Text("Решу позже")
                    } label: {
                        SettingsLabel("Вниз", gesture: .down, tone: .blue)
                    }
                } header: {
                    Text("Жесты")
                }

                Section("Карточки") {
                    Toggle(isOn: $hapticsEnabled) {
                        SettingsLabel("Вибрация", symbol: "iphone.radiowaves.left.and.right", tone: .orange)
                    }
                    Toggle(isOn: $videoSoundEnabled) {
                        SettingsLabel("Звук видео", symbol: "speaker.wave.2.fill", tone: .pink)
                    }
                    Button { showAlbums = true } label: {
                        SettingsLabel("Закреплённые альбомы", symbol: "pin.fill", tone: .violet)
                    }
                }

                Section("Оформление") {
                    Picker(selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    } label: {
                        SettingsLabel("Тема", symbol: "circle.lefthalf.filled", tone: .indigo)
                    }
                    Button { library.openSettings() } label: {
                        SettingsLabel("Язык приложения", symbol: "globe", tone: .cyan)
                    }
                }

                Section {
                    if library.isLimited {
                        Button { library.presentLimitedPicker() } label: {
                            SettingsLabel("Выбрать другие фото", symbol: "photo.badge.plus", tone: .green)
                        }
                    }
                    Button { library.openSettings() } label: {
                        SettingsLabel("Доступ к фото в Настройках", symbol: "photo.on.rectangle", tone: .blue)
                    }
                } header: {
                    Text("Медиатека")
                } footer: {
                    Text(library.isLimited ? "Сейчас открыт доступ только к части фото." as LocalizedStringKey : "Открыт доступ ко всей медиатеке.")
                }

                Section {
                    Button {
                        cacheCleared = true
                        // В кэше по файлу на каждое фото: на большой медиатеке удаление занимает секунды, главный поток его не ждёт.
                        Task.detached(priority: .utility) {
                            MetricsCache.clear()
                            FileSizeCache.shared.clear()
                        }
                    } label: {
                        SettingsLabel("Очистить кэш умной чистки", symbol: "wand.and.stars", tone: .teal)
                    }
                    .disabled(cacheCleared)
                    Button(role: .destructive) { confirmReset = true } label: {
                        SettingsLabel("Сбросить прогресс разбора", symbol: "arrow.counterclockwise", tone: .red)
                    }
                    .accessibilityIdentifier("settings.reset")
                } header: {
                    Text("Данные")
                } footer: {
                    Text("Сброс вернёт все фото в подборки. Корзина и статистика тоже очистятся, фото в медиатеке не затрагиваются.")
                }

                Section {
                    LabeledContent("Версия", value: Bundle.main.appVersion)
                } footer: {
                    Text("Удалённые фото 30 дней хранятся в альбоме «Недавно удалённые» приложения Фото.")
                }
            }
            .screenBackground()
            .navigationTitle("Настройки")
            .sheet(isPresented: $showAlbums) { AlbumPickerView() }
            .confirmationDialog("Сбросить весь прогресс?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Сбросить", role: .destructive) { store.resetProgress() }
                    .accessibilityIdentifier("settings.confirmReset")
            }
        }
    }
}

private extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

/// Строка настроек со значком на цветной плашке, как в Настройках iOS.
private struct SettingsLabel<Icon: View>: View {
    let title: LocalizedStringKey
    let icon: Icon

    var body: some View {
        Label {
            Text(title)
        } icon: {
            icon
        }
    }
}

extension SettingsLabel where Icon == ToneIcon {
    init(_ title: LocalizedStringKey, symbol: String, tone: Tone) {
        self.init(title: title, icon: ToneIcon(symbol: symbol, tone: tone, size: 28))
    }
}

extension SettingsLabel where Icon == GestureIcon {
    init(_ title: LocalizedStringKey, gesture: GestureIcon.Direction, tone: Tone) {
        self.init(title: title, icon: GestureIcon(direction: gesture, tone: tone, size: 28))
    }
}

/// Значок жеста: палец, который ведёт по экрану, и стрелка, куда он ведёт.
struct GestureIcon: View {
    enum Direction {
        case left, right, up, down
    }

    let direction: Direction
    let tone: Tone
    var size: CGFloat = 28

    var body: some View {
        Group {
            switch direction {
            case .left:
                HStack(spacing: -size * 0.04) { arrow("arrow.left"); finger }
            case .right:
                HStack(spacing: -size * 0.04) { finger; arrow("arrow.right") }
            case .up:
                VStack(spacing: -size * 0.06) { arrow("arrow.up"); finger }
            case .down:
                VStack(spacing: -size * 0.06) { finger; arrow("arrow.down") }
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(tone.gradient, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        .accessibilityHidden(true)
    }

    /// Указательный палец, касающийся экрана. Для свайпа вправо он смотрит в другую сторону.
    private var finger: some View {
        Image(systemName: "hand.point.up.left.fill")
            .font(.system(size: size * 0.42, weight: .semibold))
            .scaleEffect(x: direction == .right ? -1 : 1)
    }

    private func arrow(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.24, weight: .heavy))
    }
}
