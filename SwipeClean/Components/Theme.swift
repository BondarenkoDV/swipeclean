import SwiftUI

/// Цвета и общие элементы оформления: фирменный градиент из иконки и яркие плитки разделов.
enum Palette {
    /// Розово-коралловый край иконки.
    static let brandStart = Color(red: 0.96, green: 0.38, blue: 0.48)
    /// Фиолетовый край иконки.
    static let brandEnd = Color(red: 0.58, green: 0.33, blue: 0.93)

    static let brand = LinearGradient(colors: [brandStart, brandEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Цвет раздела: у каждой категории и инструмента свой, чтобы их было видно издалека.
enum Tone: CaseIterable {
    case pink, violet, indigo, blue, cyan, teal, green, yellow, orange, red

    /// Светлый и тёмный край градиента.
    var colors: (Color, Color) {
        switch self {
        case .pink: (Color(red: 1.0, green: 0.42, blue: 0.62), Color(red: 0.91, green: 0.22, blue: 0.5))
        case .violet: (Color(red: 0.71, green: 0.45, blue: 1.0), Color(red: 0.5, green: 0.27, blue: 0.93))
        case .indigo: (Color(red: 0.45, green: 0.47, blue: 1.0), Color(red: 0.3, green: 0.27, blue: 0.86))
        case .blue: (Color(red: 0.3, green: 0.65, blue: 1.0), Color(red: 0.13, green: 0.43, blue: 0.96))
        case .cyan: (Color(red: 0.25, green: 0.83, blue: 0.96), Color(red: 0.05, green: 0.6, blue: 0.85))
        case .teal: (Color(red: 0.2, green: 0.85, blue: 0.75), Color(red: 0.0, green: 0.62, blue: 0.6))
        case .green: (Color(red: 0.36, green: 0.88, blue: 0.48), Color(red: 0.14, green: 0.7, blue: 0.36))
        case .yellow: (Color(red: 1.0, green: 0.82, blue: 0.25), Color(red: 0.98, green: 0.63, blue: 0.05))
        case .orange: (Color(red: 1.0, green: 0.65, blue: 0.3), Color(red: 0.98, green: 0.43, blue: 0.13))
        case .red: (Color(red: 1.0, green: 0.45, blue: 0.42), Color(red: 0.92, green: 0.22, blue: 0.25))
        }
    }

    var color: Color { colors.1 }

    var gradient: LinearGradient {
        LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Значок раздела: белый символ на цветной скруглённой плашке, как в Настройках iOS, только ярче.
struct ToneIcon: View {
    let symbol: String
    let tone: Tone
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tone.gradient, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Фон экранов: системный серый с мягким цветным свечением сверху.
struct ScreenBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color(.systemGroupedBackground)
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Palette.brandStart.opacity(colorScheme == .dark ? 0.28 : 0.18), Palette.brandEnd.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 320)
            }
            .ignoresSafeArea()
    }
}

extension View {
    /// Белая (в тёмной теме — графитовая) карточка со скруглением и лёгкой тенью.
    func card(padding: CGFloat = 16, radius: CGFloat = 22) -> some View {
        self
            .padding(padding)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }

    /// Карточка, залитая градиентом: для главных блоков экрана.
    func gradientCard(_ gradient: LinearGradient = Palette.brand, padding: CGFloat = 18, radius: CGFloat = 26) -> some View {
        self
            .padding(padding)
            .foregroundStyle(.white)
            .background(gradient, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Palette.brandEnd.opacity(0.3), radius: 16, y: 8)
    }

    /// Фон экрана со свечением; списки и формы перестают рисовать свой серый фон.
    func screenBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { ScreenBackground() }
    }
}

/// Главная кнопка: фирменный градиент на всю ширину.
struct PrimaryButtonStyle: ButtonStyle {
    var gradient: LinearGradient = Palette.brand
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(.white)
            .shadow(color: Palette.brandEnd.opacity(isEnabled ? 0.3 : 0), radius: 10, y: 5)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Второстепенная кнопка: полупрозрачная плашка цвета раздела.
struct TintedButtonStyle: ButtonStyle {
    var tint: Color = Palette.brandEnd
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(tint)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

/// Кольцо заполненности с градиентом, например для памяти iPhone.
struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 14
    var colors: [Color] = [.white.opacity(0.95), .white.opacity(0.7)]
    var track: Color = .white.opacity(0.25)

    var body: some View {
        ZStack {
            Circle()
                .stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(
                    AngularGradient(colors: colors + [colors[0]], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .animation(.smooth, value: progress)
    }
}

/// Полоска прогресса с градиентом: замена серому ProgressView в карточках.
struct GradientBar: View {
    let value: Double
    var gradient: LinearGradient = Palette.brand
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(gradient)
                    .frame(width: proxy.size.width * max(0, min(value, 1)))
            }
        }
        .frame(height: height)
        .animation(.smooth, value: value)
    }
}

extension Int64 {
    /// «1,2 ГБ» в стиле Файлов.
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
