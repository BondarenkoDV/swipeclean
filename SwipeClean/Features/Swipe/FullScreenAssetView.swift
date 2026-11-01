import AVKit
import Photos
import SwiftUI

/// Какой ассет открыт на весь экран. Окно одно на всё приложение и висит на TabView: когда у стопки
/// и у корзины было по своему fullScreenCover, при включённых специальных возможностях (VoiceOver, UI-тесты)
/// iOS 27 оставляла один из этих экранов пустым белым. Экраны только задают `asset`.
@MainActor
@Observable
final class FullScreenPresenter {
    var asset: PHAsset?
    /// Фото, которое всплыло поверх экрана, пока палец удерживает превью (см. `peekAndPop`).
    var peek: PHAsset?

    /// Сколько держать палец, чтобы фото всплыло поверх экрана.
    static let peekDelay = 0.3
    /// Сколько держать после этого, чтобы фото открылось на весь экран.
    static let popDelay = 0.7
}

extension View {
    /// Удержание превью: сначала фото всплывает поверх экрана, а если держать дальше, открывается целиком.
    /// Отпустил раньше — фото закрывается. Короткий тап остаётся за `onTap`.
    func peekAndPop(_ asset: PHAsset, onTap: @escaping () -> Void) -> some View {
        modifier(PeekAndPop(asset: asset, onTap: onTap))
    }
}

private struct PeekAndPop: ViewModifier {
    let asset: PHAsset
    let onTap: () -> Void

    @Environment(FullScreenPresenter.self) private var presenter
    /// Палец на превью: от касания до отпускания или до открытия целиком.
    @State private var isHolding = false
    /// За это касание фото уже всплывало: отпускание после него не считается тапом.
    @State private var didPeek = false
    @State private var pops = 0

    func body(content: Content) -> some View {
        content
            // Тап и удержание — отдельные жесты, как в onTapGesture + onLongPressGesture до этого.
            // Составной жест с DragGesture(minimumDistance: 0) забирал касание целиком: ряд не листался,
            // а тап не срабатывал; LongPressGesture через .gesture ждал, пока тап не отвалится.
            .onTapGesture {
                guard !didPeek else { return }
                onTap()
            }
            .onLongPressGesture(
                minimumDuration: FullScreenPresenter.peekDelay + FullScreenPresenter.popDelay,
                maximumDistance: 10
            ) {
                // Под полноэкранным просмотром отпускание сюда не доходит: сбрасываем удержание сами.
                isHolding = false
                presenter.peek = nil
                presenter.asset = asset
                pops += 1
            } onPressingChanged: { pressing in
                // Новое касание: пока фото не всплыло, отпускание снова считается тапом.
                if pressing { didPeek = false }
                isHolding = pressing
            }
            .onChange(of: isHolding) { _, holding in
                if !holding, presenter.peek == asset {
                    presenter.peek = nil
                }
            }
            .task(id: isHolding) {
                guard isHolding else { return }
                try? await Task.sleep(for: .seconds(FullScreenPresenter.peekDelay))
                // Палец отпустили раньше: задача отменена вместе со сменой isHolding.
                guard !Task.isCancelled else { return }
                didPeek = true
                presenter.peek = asset
            }
            .sensoryFeedback(.impact(weight: .light), trigger: didPeek) { _, peeked in peeked }
            .sensoryFeedback(.impact(weight: .medium), trigger: pops)
    }
}

/// Фото поверх экрана, пока палец удерживает превью. Касания проходят насквозь: жест ведёт само превью.
struct PeekView: View {
    let asset: PHAsset
    @State private var image: UIImage?
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .black.opacity(0.3), radius: 20)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 8) {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(.secondary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 16, height: 16)
                    Text("Держите, чтобы открыть целиком")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("fullscreen.peek")
        .onAppear {
            withAnimation(.linear(duration: FullScreenPresenter.popDelay)) { progress = 1 }
        }
        .task(id: asset.localIdentifier) {
            let loader = AssetImageLoader.shared
            image = await loader.image(for: asset, targetSize: loader.cardTargetSize, contentMode: .aspectFit)
        }
    }
}

/// Полноэкранный просмотр: фото с зумом щипком, двойным тапом и перетаскиванием увеличенного кадра,
/// видео — со звуком и стандартными кнопками плеера.
struct FullScreenAssetView: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss
    @Environment(ProtectedStore.self) private var protection
    @Environment(ReviewStore.self) private var store
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var loadFailed = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private static let maxZoom: CGFloat = 4

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea(edges: .bottom)
            } else if let image {
                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(zoom(in: proxy.size).simultaneously(with: pan(in: proxy.size)))
                        .onTapGesture(count: 2) {
                            withAnimation {
                                scale = scale > 1 ? 1 : 2.5
                                lastScale = scale
                                offset = .zero
                                lastOffset = .zero
                            }
                        }
                }
            } else if loadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.icloud")
                        .font(.largeTitle)
                    Text("Не удалось загрузить фото")
                }
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.3))
            }
            .padding()
            .accessibilityLabel("Закрыть")
            .accessibilityIdentifier("fullscreen.close")
        }
        .overlay(alignment: .topLeading) {
            protectButton
                .padding()
        }
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    /// «Не трогать»: защищённое фото приложение больше не предлагает удалить нигде. Если фото открыто из стопки
    /// или сетки, после защиты оно оттуда пропадает, а из корзины приложения возвращается.
    @ViewBuilder
    private var protectButton: some View {
        let id = asset.localIdentifier
        let isListed = protection.contains(id)
        if !isListed, protection.protectsFavorites, asset.isFavorite {
            // Избранное и так защищено: снять защиту можно только выключив её для всего избранного.
            Label("Избранное не трогаю", systemImage: "lock.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Tone.green.gradient, in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("fullscreen.protectedFavorite")
        } else {
            Button {
                if isListed {
                    protection.remove([id])
                } else {
                    protection.protect([id], store: store)
                }
            } label: {
                Label(isListed ? "Не трогаю" : "Не трогать", systemImage: isListed ? "lock.shield.fill" : "lock.shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        Capsule().fill(isListed ? AnyShapeStyle(Tone.green.gradient) : AnyShapeStyle(.white.opacity(0.22)))
                    }
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: isListed) { _, listed in listed }
            .accessibilityValue(isListed ? "Защищено" : "Не защищено")
            .accessibilityHint("Защищённое фото не попадёт в разбор, умную чистку и сжатие")
            .accessibilityIdentifier("fullscreen.protect")
        }
    }

    private func zoom(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(Self.maxZoom, max(1, lastScale * value.magnification))
                offset = clamped(offset, in: size)
            }
            .onEnded { _ in
                lastScale = scale
                lastOffset = offset
            }
    }

    /// Увеличенный кадр можно двигать, иначе при зуме был виден только центр.
    private func pan(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = clamped(
                    CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height),
                    in: size
                )
            }
            .onEnded { _ in lastOffset = offset }
    }

    /// Край увеличенного кадра не уходит дальше края экрана.
    private func clamped(_ offset: CGSize, in size: CGSize) -> CGSize {
        let limitX = size.width * (scale - 1) / 2
        let limitY = size.height * (scale - 1) / 2
        return CGSize(
            width: min(limitX, max(-limitX, offset.width)),
            height: min(limitY, max(-limitY, offset.height))
        )
    }

    private func load() async {
        // Двукратного размера экрана хватает для зума; оригинал в 48 Мп занял бы сотни мегабайт памяти.
        let loader = AssetImageLoader.shared
        let target = CGSize(width: loader.cardTargetSize.width * 2, height: loader.cardTargetSize.height * 2)
        let loaded = await loader.image(for: asset, targetSize: target, contentMode: .aspectFit)
        guard !Task.isCancelled else { return }
        image = loaded
        loadFailed = loaded == nil

        // Видео в полный экран открывают, чтобы посмотреть его перед решением, поэтому оно играет со звуком.
        guard asset.mediaType == .video, let item = await loader.playerItem(for: asset), !Task.isCancelled else { return }
        let player = AVPlayer(playerItem: item)
        self.player = player
        player.play()
    }
}
