import LocalAuthentication
import SwiftUI

/// Экран ввода PIN-кода из четырёх цифр с цифровой клавиатурой.
/// `onComplete` получает код и возвращает false, если он не подошёл: тогда точки трясутся и ввод начинается заново.
struct PasscodeView: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var biometryType: LABiometryType = .none
    var onBiometrics: (() -> Void)?
    /// Цифры не нажимаются: идёт пауза после неверных попыток. Face ID работает.
    var isLocked = false
    let onComplete: (String) -> Bool

    @State private var code = ""
    @State private var attempts = 0

    static let length = 4

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 12)
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(Tone.indigo.gradient, in: Circle())
                .shadow(color: Tone.indigo.color.opacity(0.4), radius: 12, y: 6)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.bold())
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            HStack(spacing: 18) {
                ForEach(0..<Self.length, id: \.self) { index in
                    Circle()
                        .fill(index < code.count ? AnyShapeStyle(Tone.indigo.gradient) : AnyShapeStyle(Color(.tertiarySystemFill)))
                        .frame(width: 16, height: 16)
                }
            }
            // Неверный код: точки покачиваются влево-вправо.
            .keyframeAnimator(initialValue: CGFloat(0), trigger: attempts) { content, offset in
                content.offset(x: offset)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(-12, duration: 0.06)
                    LinearKeyframe(12, duration: 0.06)
                    LinearKeyframe(-8, duration: 0.06)
                    LinearKeyframe(8, duration: 0.06)
                    LinearKeyframe(0, duration: 0.06)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Введено цифр: \(code.count)"))
            .accessibilityIdentifier("pin.dots")
            Spacer(minLength: 12)
            keypad
            Spacer(minLength: 8)
        }
        .sensoryFeedback(.error, trigger: attempts)
    }

    private var keypad: some View {
        VStack(spacing: 14) {
            ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]], id: \.self) { row in
                HStack(spacing: 22) {
                    ForEach(row, id: \.self) { digit in key(digit) }
                }
            }
            HStack(spacing: 22) {
                if let onBiometrics, biometryType != .none {
                    Button(action: onBiometrics) {
                        Image(systemName: biometryType == .touchID ? "touchid" : "faceid")
                            .font(.title)
                            .frame(width: 76, height: 76)
                    }
                    .accessibilityLabel(biometryType == .touchID ? "Touch ID" : "Face ID")
                    .accessibilityIdentifier("pin.biometrics")
                } else {
                    Color.clear.frame(width: 76, height: 76)
                }
                key("0")
                Button {
                    if !code.isEmpty { code.removeLast() }
                } label: {
                    Image(systemName: "delete.left")
                        .font(.title2)
                        .frame(width: 76, height: 76)
                }
                .disabled(code.isEmpty)
                .accessibilityLabel("Стереть")
                .accessibilityIdentifier("pin.delete")
            }
        }
        .foregroundStyle(.primary)
    }

    private func key(_ digit: String) -> some View {
        Button {
            enter(digit)
        } label: {
            Text(digit)
                .font(.system(.title, design: .rounded, weight: .medium))
                .frame(width: 76, height: 76)
                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .opacity(isLocked ? 0.4 : 1)
        .accessibilityIdentifier("pin.\(digit)")
    }

    private func enter(_ digit: String) {
        guard code.count < Self.length else { return }
        code.append(digit)
        guard code.count == Self.length else { return }
        let entered = code
        // Даём последней точке заполниться, прежде чем экран сменится или затрясётся.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if !onComplete(entered) {
                attempts += 1
            }
            code = ""
        }
    }
}
