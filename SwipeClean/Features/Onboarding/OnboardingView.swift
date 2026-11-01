import SwiftUI

struct OnboardingView: View {
    @Environment(PhotoLibraryService.self) private var library
    @State private var page: Int

    let onFinish: () -> Void

    init(startsAtAccessPage: Bool = false, onFinish: @escaping () -> Void) {
        _page = State(initialValue: startsAtAccessPage ? Self.pages.count : 0)
        self.onFinish = onFinish
    }

    private static let pages: [OnboardingPage] = [
        OnboardingPage(
            symbol: "hand.draw.fill",
            tone: .orange,
            title: String(localized: "Свайпайте фото"),
            text: String(localized: "Влево — в корзину, вправо — оставить. Вверх — в избранное, вниз — решу позже.")
        ),
        OnboardingPage(
            symbol: "trash.fill",
            tone: .red,
            title: String(localized: "Ничего не пропадёт случайно"),
            text: String(localized: "Всё удалённое сначала попадает в корзину приложения. Вы проверяете её и удаляете одним подтверждением.")
        ),
        OnboardingPage(
            symbol: "wand.and.stars",
            tone: .violet,
            title: String(localized: "Умная чистка"),
            text: String(localized: "Похожие кадры, дубликаты, размытые фото и старые скриншоты — найдём и сгруппируем.")
        ),
        OnboardingPage(
            symbol: "square.grid.2x2.fill",
            tone: .green,
            title: String(localized: "Ещё больше места"),
            text: String(localized: "Сжатие фото и видео, секретная папка с PIN-кодом, чистка контактов, календаря и почты iCloud и Gmail от спама.")
        ),
    ]

    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $page) {
                ForEach(Self.pages.indices, id: \.self) { index in
                    OnboardingPageView(page: Self.pages[index])
                        .tag(index)
                }
                accessPage
                    .tag(Self.pages.count)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            primaryButton
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .background { ScreenBackground() }
    }

    private var accessPage: some View {
        VStack(spacing: 16) {
            Spacer()
            OnboardingBadge(symbol: library.isDenied ? "lock.slash.fill" : "photo.on.rectangle.angled", tone: library.isDenied ? .red : .blue)
            Text(library.isDenied ? "Нет доступа к фото" as LocalizedStringKey : "Доступ к фото")
                .font(.title.bold())
            Text(accessText)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private var accessText: String {
        if library.isDenied {
            return String(localized: "Откройте Настройки и разрешите доступ ко всем фото, иначе разбирать будет нечего.")
        }
        if library.isLimited {
            return String(localized: "Сейчас доступ ограничен выбранными фото. Для полной чистки лучше разрешить доступ ко всей медиатеке.")
        }
        return String(localized: "Фото обрабатываются только на устройстве и никуда не отправляются.")
    }

    @ViewBuilder
    private var primaryButton: some View {
        if page < Self.pages.count {
            Button("Далее") {
                withAnimation { page += 1 }
            }
            .buttonStyle(PrimaryButtonStyle())
        } else if library.isDenied {
            Button("Открыть Настройки") { library.openSettings() }
                .buttonStyle(PrimaryButtonStyle())
        } else if library.hasAccess {
            VStack(spacing: 12) {
                Button("Начать") { onFinish() }
                    .buttonStyle(PrimaryButtonStyle())
                if library.isLimited {
                    Button("Выбрать другие фото") { library.presentLimitedPicker() }
                        .font(.subheadline)
                }
            }
        } else {
            Button("Разрешить доступ") {
                Task {
                    await library.requestAccess()
                    if library.hasAccess && !library.isLimited { onFinish() }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

private struct OnboardingPage {
    let symbol: String
    let tone: Tone
    let title: String
    let text: String
}

/// Крупный значок страницы в цветном круге со свечением.
private struct OnboardingBadge: View {
    let symbol: String
    let tone: Tone

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 54, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 132, height: 132)
            .background(tone.gradient, in: Circle())
            .shadow(color: tone.color.opacity(0.45), radius: 24, y: 10)
            .padding(.bottom, 8)
            .accessibilityHidden(true)
    }
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            OnboardingBadge(symbol: page.symbol, tone: page.tone)
            Text(page.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(page.text)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
        }
    }
}

#Preview {
    OnboardingView {}
        .environment(PhotoLibraryService())
}
