import AVKit
import Photos
import PhotosUI
import SwiftUI

/// Одна карточка: фото, видео или Live Photo плюс метаданные.
struct SwipeCardView: View {
    let asset: PHAsset
    let isTop: Bool

    @State private var image: UIImage?
    @State private var downloadProgress: Double?
    /// Фото не загрузилось (нет сети для iCloud, фото удалили): вместо вечного индикатора — сообщение и повтор.
    @State private var loadFailed = false
    @State private var attempt = 0
    @State private var fileSize: Int64?
    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?
    @State private var livePhoto: PHLivePhoto?
    @State private var livePhotoTask: Task<Void, Never>?
    @State private var isPlayingLive = false

    private var isLivePhoto: Bool {
        asset.mediaSubtypes.contains(.photoLive)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                media
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)

                metadata
                    .padding(16)
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(isTop ? 0.2 : 0), radius: 12, y: 6)
            .task(id: "\(asset.localIdentifier)#\(attempt)") {
                await load()
            }
            .onChange(of: isTop) { _, top in
                if top { player?.play() } else { player?.pause() }
            }
            .onDisappear(perform: tearDown)
        }
    }

    private var media: some View {
        Group {
            if let player, asset.mediaType == .video {
                VideoPlayer(player: player)
                    .disabled(true)
            } else if let livePhoto, isPlayingLive {
                LivePhotoView(livePhoto: livePhoto)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if loadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.icloud")
                        .font(.largeTitle)
                    Text("Не удалось загрузить фото")
                        .font(.subheadline)
                    Text("Проверьте интернет: оригинал может храниться только в iCloud. Решение можно принять и так.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("Повторить") {
                        downloadProgress = nil
                        attempt += 1
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("card.retry")
                }
                .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    if let downloadProgress {
                        Text("Загрузка из iCloud \(Int(downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        // Жест стоит на контейнере, а не на картинке: когда вместо неё показывается Live Photo,
        // отпускание пальца всё равно доходит и возвращает статичный кадр.
        .onLongPressGesture(minimumDuration: 0.3) {} onPressingChanged: { pressing in
            guard isLivePhoto else { return }
            isPlayingLive = pressing
            if pressing { loadLivePhotoIfNeeded() }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if asset.mediaType == .video {
                    Label(asset.duration.formattedDuration, systemImage: "video.fill")
                }
                if isLivePhoto {
                    Label("Live", systemImage: "livephoto")
                }
                if asset.mediaSubtypes.contains(.photoScreenshot) {
                    Label("Скриншот", systemImage: "camera.viewfinder")
                }
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                }
            }
            .font(.caption.weight(.semibold))

            if let date = asset.creationDate {
                Text(date.formatted(date: .long, time: .shortened))
                    .font(.subheadline.weight(.medium))
            }
            if let fileSize, fileSize > 0 {
                Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
                    .font(.caption)
            }
        }
        .foregroundStyle(.white)
        .labelStyle(.titleAndIcon)
    }

    /// Картинка запрашивается в том же размере, что и предзагрузка стопки, чтобы попадать в кэш PhotoKit.
    private func load() async {
        let loader = AssetImageLoader.shared
        if image == nil {
            loadFailed = false
            let loaded = await loader.image(for: asset, targetSize: loader.cardTargetSize) { progress in
                Task { @MainActor in downloadProgress = progress }
            }
            guard !Task.isCancelled else { return }
            image = loaded
            loadFailed = loaded == nil
        }

        if fileSize == nil {
            // Размер берётся из ресурсов PhotoKit; раньше он считался прямо в body на главном потоке при каждой перерисовке.
            let asset = asset
            let size = await Task.detached(priority: .utility) { asset.cachedFileSize }.value
            guard !Task.isCancelled else { return }
            fileSize = size
        }

        if asset.mediaType == .video, player == nil {
            guard let item = await loader.playerItem(for: asset), !Task.isCancelled else { return }
            let player = AVPlayer(playerItem: item)
            player.isMuted = !UserDefaults.standard.bool(forKey: SettingsKeys.videoSoundEnabled)
            player.actionAtItemEnd = .none
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
            self.player = player
            if isTop { player.play() }
        }
    }

    /// Live Photo весит как видео, поэтому подгружается только когда пользователь его зажал.
    private func loadLivePhotoIfNeeded() {
        guard livePhoto == nil, livePhotoTask == nil else { return }
        let asset = asset
        livePhotoTask = Task {
            let loader = AssetImageLoader.shared
            let loaded = await loader.livePhoto(for: asset, targetSize: loader.cardTargetSize)
            guard !Task.isCancelled else { return }
            livePhoto = loaded
            livePhotoTask = nil
        }
    }

    /// Снимает наблюдателя зацикливания и останавливает плеер, иначе они живут после ухода карточки.
    private func tearDown() {
        player?.pause()
        player = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        livePhotoTask?.cancel()
        livePhotoTask = nil
    }
}

private struct LivePhotoView: UIViewRepresentable {
    let livePhoto: PHLivePhoto

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFill
        view.isMuted = true
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        view.livePhoto = livePhoto
        view.startPlayback(with: .full)
    }
}

extension TimeInterval {
    var formattedDuration: String {
        let total = Int(rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
