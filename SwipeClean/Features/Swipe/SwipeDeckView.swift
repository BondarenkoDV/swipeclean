import Photos
import SwiftUI

/// Экран свайпов: стопка из двух карточек, жесты в четыре стороны и кнопки-дубли.
struct SwipeDeckView: View {
    @State private var model: SwipeDeckViewModel
    @Environment(PhotoLibraryService.self) private var library
    @Environment(FullScreenPresenter.self) private var fullScreen
    @Environment(ProtectedStore.self) private var protection
    @State private var offset: CGSize = .zero
    @State private var hapticTrigger = 0
    @AppStorage(SettingsKeys.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(SettingsKeys.swapHorizontalSwipes) private var swapHorizontal = false

    @State private var showAlbumPicker = false
    @State private var isAnimatingOut = false
    /// Похвала за взятую веху: показывается пару секунд поверх стопки.
    @State private var celebration: Int64?

    var onDecision: (SwipeDeckViewModel.Action) -> Void
    var onUndo: (SwipeDeckViewModel.Action) -> Void

    private let threshold: CGFloat = 110

    init(
        title: String,
        assets: [PHAsset],
        onDecision: @escaping (SwipeDeckViewModel.Action) -> Void = { _ in },
        onUndo: @escaping (SwipeDeckViewModel.Action) -> Void = { _ in }
    ) {
        _model = State(initialValue: SwipeDeckViewModel(title: title, assets: assets))
        self.onDecision = onDecision
        self.onUndo = onUndo
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            deck
            PinnedAlbumsBar(onSelect: { commit(.keep, albumID: $0) }, onManage: { showAlbumPicker = true })
                .disabled(model.isFinished)
            controls
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background { ScreenBackground() }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: library.changeCount) { _, _ in Task { await model.dropMissing() } }
        // Фото защитили в полноэкранном просмотре: карточка уходит из стопки без решения.
        .onChange(of: protection.policy) { _, policy in model.dropProtected(policy) }
        .sensoryFeedback(.impact(weight: .medium), trigger: hapticTrigger) { _, _ in hapticsEnabled }
        .sensoryFeedback(.success, trigger: model.milestoneCount) { _, _ in hapticsEnabled }
        .overlay(alignment: .top) {
            if let celebration {
                MilestoneToast(bytes: celebration)
                    .padding(.top, 52)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task(id: model.milestoneCount) {
            guard model.milestoneCount > 0, let reached = model.milestone else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { celebration = reached }
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { celebration = nil }
        }
        .sheet(isPresented: $showAlbumPicker) {
            AlbumPickerView()
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            GradientBar(value: model.progress, height: 6)
            HStack {
                Text("\(min(model.index + 1, model.assets.count)) из \(model.assets.count)")
                    .accessibilityIdentifier("deck.position")
                Spacer()
                Label("\(model.counts[.trash, default: 0])", systemImage: "trash.fill")
                    .foregroundStyle(Tone.red.color)
                Label("\(model.counts[.keep, default: 0])", systemImage: "checkmark")
                    .foregroundStyle(Tone.green.color)
                Label("\(model.counts[.favorite, default: 0])", systemImage: "heart.fill")
                    .foregroundStyle(Tone.pink.color)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            freedCounter
        }
    }

    /// Сколько места уже набралось к удалению: растёт с каждым свайпом в корзину, чтобы хотелось продолжать.
    private var freedCounter: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .symbolEffect(.bounce, value: model.trashBytes)
            Text("Освободится \(model.trashBytes.formattedBytes)")
                .contentTransition(.numericText(value: Double(model.trashBytes)))
            Spacer(minLength: 4)
            if let next = nextMilestone {
                Text("до \(next.formattedBytes)")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.85)
                GradientBar(
                    value: milestoneProgress(to: next),
                    gradient: LinearGradient(colors: [.white, .white.opacity(0.75)], startPoint: .leading, endPoint: .trailing),
                    height: 5
                )
                .frame(width: 56)
            }
        }
        .font(.subheadline.weight(.bold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.brand, in: Capsule())
        .animation(.snappy, value: model.trashBytes)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("deck.freed")
    }

    /// Путь от прошлой вехи до следующей: полоска заполняется заново после каждой.
    private func milestoneProgress(to next: Int64) -> Double {
        let previous = SwipeDeckViewModel.milestone(for: model.trashBytes) ?? 0
        guard next > previous else { return 1 }
        return Double(model.trashBytes - previous) / Double(next - previous)
    }

    /// Следующая веха, к которой идёт счётчик.
    private var nextMilestone: Int64? {
        let step: Int64 = 5 * 1024 * 1024 * 1024
        if let next = SwipeDeckViewModel.milestones.first(where: { $0 > model.trashBytes }) {
            return next
        }
        return (model.trashBytes / step + 1) * step
    }

    @ViewBuilder
    private var deck: some View {
        if model.isFinished {
            ContentUnavailableView {
                Label("Готово", systemImage: "checkmark.seal")
            } description: {
                Text("Вы разобрали все фото в этой подборке. Удалённые лежат в корзине и ждут подтверждения.")
            } actions: {
                if model.canUndo {
                    Button("Вернуть последнее", action: undo)
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            ZStack {
                // Обе карточки в одном ForEach: когда следующая становится верхней, SwiftUI сохраняет её
                // вместе с загруженным фото и плеером, а не создаёт заново с повторной загрузкой.
                ForEach(visibleCards, id: \.localIdentifier) { asset in
                    card(for: asset, isTop: asset.localIdentifier == model.current?.localIdentifier)
                }
                if model.current != nil {
                    sideIndicators
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// Следующая карточка снизу, текущая сверху.
    private var visibleCards: [PHAsset] {
        [model.next, model.current].compactMap { $0 }
    }

    private func card(for asset: PHAsset, isTop: Bool) -> some View {
        SwipeCardView(asset: asset, isTop: isTop)
            .overlay {
                if isTop { decisionTint }
            }
            .overlay(alignment: .top) {
                if isTop { decisionBadge }
            }
            .scaleEffect(isTop ? 1 : 0.95)
            .offset(isTop ? offset : .zero)
            .rotationEffect(.degrees(isTop ? Double(offset.width / 20) : 0))
            .gesture(dragGesture)
            .onTapGesture { fullScreen.asset = asset }
            .allowsHitTesting(isTop)
            .accessibilityIdentifier(isTop ? "deck.card" : "deck.next")
            .transition(.identity)
    }

    /// Насколько далеко утащена карточка: 0 — на месте, 1 — решение сработает.
    private var dragProgress: Double {
        min(1, max(abs(offset.width), abs(offset.height)) / threshold)
    }

    private var isHorizontalDrag: Bool {
        abs(offset.width) >= abs(offset.height)
    }

    /// Цветная заливка карточки в цвет решения, растёт по мере свайпа.
    @ViewBuilder
    private var decisionTint: some View {
        if let decision = pendingDecision {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(color(for: decision).opacity(0.35 * dragProgress))
                .allowsHitTesting(false)
        }
    }

    /// Крупные значки «Удалить» и «Оставить» у краёв экрана при свайпе влево и вправо.
    private var sideIndicators: some View {
        let left: SwipeDecision = swapHorizontal ? .keep : .trash
        let right: SwipeDecision = swapHorizontal ? .trash : .keep
        let active = isHorizontalDrag && pendingDecision != nil ? dragProgress : 0
        return HStack {
            DecisionIndicator(decision: left, tint: color(for: left), progress: offset.width < 0 ? active : 0)
            Spacer()
            DecisionIndicator(decision: right, tint: color(for: right), progress: offset.width > 0 ? active : 0)
        }
        .padding(.horizontal, 12)
        .allowsHitTesting(false)
    }

    /// Значок сверху для вертикальных свайпов: избранное и «позже».
    @ViewBuilder
    private var decisionBadge: some View {
        if let decision = pendingDecision, !isHorizontalDrag {
            DecisionIndicator(decision: decision, tint: color(for: decision), progress: dragProgress)
                .padding(.top, 20)
                .allowsHitTesting(false)
        }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            CircleButton(symbol: "arrow.uturn.backward", label: String(localized: "Вернуть последнее"), tint: .gray, size: 48, action: undo)
                .accessibilityIdentifier("deck.undo")
                .disabled(!model.canUndo)
            // Кнопки стоят с той же стороны, куда уходит карточка.
            let left: SwipeDecision = swapHorizontal ? .keep : .trash
            let right: SwipeDecision = swapHorizontal ? .trash : .keep
            CircleButton(symbol: left.symbol, label: left.label, tint: color(for: left), size: 64, isFilled: true) { commit(left) }
                .accessibilityIdentifier("deck.\(left.rawValue)")
            CircleButton(symbol: SwipeDecision.later.symbol, label: SwipeDecision.later.label, tint: color(for: .later), size: 48) { commit(.later) }
                .accessibilityIdentifier("deck.later")
            CircleButton(symbol: SwipeDecision.favorite.symbol, label: SwipeDecision.favorite.label, tint: color(for: .favorite), size: 48) { commit(.favorite) }
                .accessibilityIdentifier("deck.favorite")
            CircleButton(symbol: right.symbol, label: right.label, tint: color(for: right), size: 64, isFilled: true) { commit(right) }
                .accessibilityIdentifier("deck.\(right.rawValue)")
        }
        .disabled(model.isFinished)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // Пока карточка улетает, новый жест не должен перехватывать её положение.
                guard !isAnimatingOut else { return }
                offset = value.translation
            }
            .onEnded { value in
                guard !isAnimatingOut else { return }
                if let decision = decision(for: value.predictedEndTranslation) ?? decision(for: value.translation) {
                    commit(decision)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { offset = .zero }
                }
            }
    }

    private var pendingDecision: SwipeDecision? {
        decision(for: offset, threshold: 20)
    }

    private func decision(for translation: CGSize, threshold: CGFloat? = nil) -> SwipeDecision? {
        let limit = threshold ?? self.threshold
        let dx = translation.width
        let dy = translation.height
        if abs(dx) >= abs(dy) {
            guard abs(dx) > limit else { return nil }
            let toLeft = dx < 0
            return toLeft != swapHorizontal ? .trash : .keep
        } else {
            guard abs(dy) > limit else { return nil }
            return dy < 0 ? .favorite : .later
        }
    }

    private func commit(_ decision: SwipeDecision, albumID: String? = nil) {
        guard model.current != nil, !isAnimatingOut else { return }
        isAnimatingOut = true
        let exit: CGSize = switch decision {
        case .trash: CGSize(width: swapHorizontal ? 800 : -800, height: offset.height)
        case .keep: CGSize(width: swapHorizontal ? -800 : 800, height: offset.height)
        case .favorite: CGSize(width: offset.width, height: -1200)
        case .later: CGSize(width: offset.width, height: 1200)
        }
        hapticTrigger += 1
        withAnimation(.easeIn(duration: 0.2)) { offset = exit } completion: {
            if let action = model.decide(decision, albumID: albumID) {
                onDecision(action)
            }
            offset = .zero
            isAnimatingOut = false
        }
    }

    private func undo() {
        // Пока карточка улетает, решение по ней ещё не записано: отмена в этот момент
        // откатила бы предыдущее фото, а улетающее решение досталось бы ему.
        guard !isAnimatingOut, let action = model.undo() else { return }
        hapticTrigger += 1
        onUndo(action)
    }

    private func color(for decision: SwipeDecision) -> Color {
        switch decision {
        case .trash: .red
        case .keep: .green
        case .favorite: Color(red: 1.0, green: 0.72, blue: 0.0)
        case .later: .blue
        }
    }
}

/// Похвала за веху: «Уже 1 ГБ!» на цветной плашке.
private struct MilestoneToast: View {
    let bytes: Int64

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trophy.fill")
                .font(.title3)
                .symbolEffect(.bounce, value: bytes)
            VStack(alignment: .leading, spacing: 1) {
                Text("Уже \(bytes.formattedBytes)!")
                    .font(.headline)
                Text("Так держать, ещё немного")
                    .font(.caption)
                    .opacity(0.9)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Tone.orange.gradient, in: Capsule())
        .shadow(color: Tone.orange.color.opacity(0.45), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("deck.milestone")
    }
}

/// Значок решения: круг с иконкой и мягким свечением, подпись под ним.
private struct DecisionIndicator: View {
    let decision: SwipeDecision
    let tint: Color
    let progress: Double

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: decision.symbol)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(tint.gradient, in: Circle())
                .shadow(color: tint.opacity(0.8), radius: 16)
            Text(decision.label)
                .font(.system(.footnote, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .lineLimit(1)
                .fixedSize()
        }
        .scaleEffect(0.7 + 0.3 * progress)
        .opacity(progress)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: progress >= 1)
        .accessibilityHidden(true)
    }
}

private struct CircleButton: View {
    let symbol: String
    /// Подпись для VoiceOver: на кнопке только значок.
    let label: String
    let tint: Color
    let size: CGFloat
    /// Главные кнопки (удалить и оставить) залиты цветом, остальные — полупрозрачные.
    var isFilled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .frame(width: size, height: size)
                .background {
                    if isFilled {
                        Circle().fill(tint.gradient)
                            .shadow(color: tint.opacity(0.45), radius: 10, y: 5)
                    } else {
                        Circle().fill(tint.opacity(0.15))
                    }
                }
                .foregroundStyle(isFilled ? .white : tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

extension PHAsset: @retroactive Identifiable {
    public var id: String { localIdentifier }
}
