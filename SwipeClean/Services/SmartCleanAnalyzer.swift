import Foundation
import Photos
import UIKit
import Vision

/// Сканирует медиатеку и собирает группы для умной чистки.
/// Каждый запуск независим: прошлые результаты и метрики стираются, и все фото и видео проверяются заново.
/// Диск служит только черновиком внутри запуска: отпечатки Vision лежат отдельными файлами и читаются
/// лишь при сравнении соседних кадров, поэтому память не растёт вместе с размером медиатеки.
@MainActor
@Observable
final class SmartCleanAnalyzer {
    enum State: Equatable {
        case idle
        case scanning(done: Int, total: Int)
        case finished
    }

    private(set) var state: State = .idle
    private(set) var similar: [AssetGroup] = []
    private(set) var duplicates: [AssetGroup] = []
    private(set) var bursts: [AssetGroup] = []
    private(set) var blurry: [PHAsset] = []
    private(set) var oldScreenshots: [PHAsset] = []
    private(set) var videoDuplicates: [AssetGroup] = []
    private(set) var heavyVideos: [PHAsset] = []
    /// Фото, для которых не удалось получить превью без сети (оригинал только в iCloud): они не проверены.
    private(set) var unavailable = 0

    private var worker: Task<Result, Never>?
    /// Отменённый запуск ещё может дописывать кэш: новый ждёт его, чтобы они не перезаписывали файлы друг друга.
    private var cancelledWorker: Task<Result, Never>?
    /// Номер запуска: прогресс и результат старого запуска после отмены игнорируются.
    private var generation = 0

    /// Порог расстояния Vision для «похожих» кадров и максимальный разрыв во времени между ними.
    nonisolated static let similarDistance: Float = 0.45
    nonisolated static let similarTimeWindow: TimeInterval = 10 * 60
    nonisolated static let blurThreshold = 60.0
    nonisolated static let screenshotAge: TimeInterval = 30 * 24 * 3600
    /// Видео-кандидаты в дубли: длительность отличается не больше чем на секунду, а хэши обложек почти совпадают.
    /// Дублем пара считается, только если обложки совпадают и попиксельно, как у фото.
    nonisolated static let videoDurationTolerance: TimeInterval = 1
    nonisolated static let videoHashTolerance = 6
    nonisolated static let heavyVideoSize: Int64 = 100 * 1024 * 1024
    /// Сторона превью, по которому считаются метрики фото, и кадра-обложки видео.
    nonisolated static let photoThumbnailSide: CGFloat = 300
    nonisolated static let videoThumbnailSide: CGFloat = 64
    /// Дубликаты фото — только копии одного и того же кадра (пересохранённые, уменьшенные, в другом формате).
    /// Кандидаты: хэши отличаются не больше чем на 3 бита, пропорции и средние цвета совпадают, кадр не однотонный.
    /// Решает попиксельное сравнение копий 64×64. Соседние кадры серии с другим выражением лица или сдвигом камеры
    /// Vision считает почти одинаковыми, поэтому раньше они попадали в дубли; теперь они остаются в «Похожих».
    nonisolated static let duplicateHashTolerance = 3
    nonisolated static let duplicateMinContrast = 8.0
    /// Насколько могут отличаться средние цвета дублей: пересжатие укладывается, другой цвет нет.
    nonisolated static let duplicateColorTolerance = 12.0
    /// Допуски попиксельного сравнения (яркость 0…255 после вычитания общего сдвига): средняя разница
    /// и разница в самом непохожем блоке 4×4. На симуляторе копии (JPEG 40 %, уменьшение до 80 %) дали не больше
    /// 0,61 и 1,2, соседние кадры серии — от 2,49 и 28. Кадр серии отсекает блок; среднее с запасом ниже 2,49.
    nonisolated static let exactMeanTolerance = 1.5
    nonisolated static let exactBlockTolerance = 10.0
    /// Скриншоты одного приложения отличаются только текстом, который хэш 9×8 не видит,
    /// поэтому для пары скриншотов требуется точное совпадение хэша, почти одинаковые цвета и более строгие допуски.
    nonisolated static let screenshotColorTolerance = 4.0
    nonisolated static let screenshotMeanTolerance = 1.0
    nonisolated static let screenshotBlockTolerance = 4.0
    /// Корзина кандидатов больше этого размера считается вырожденной (однотонные кадры) и пропускается.
    nonisolated static let duplicateBucketLimit = 2000
    /// Сколько фото обрабатывается параллельно за один шаг первого прохода.
    nonisolated static let batchSize = 32

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    /// Сканирует фото, снятые в пределах `interval`; `nil` — вся медиатека.
    func scan(in interval: DateInterval? = nil) {
        guard !isScanning else { return }
        // Прошлые находки не доживают до нового запуска, даже если он оборвётся.
        clearResults()
        generation += 1
        let generation = self.generation
        state = .scanning(done: 0, total: 0)
        let previous = cancelledWorker
        cancelledWorker = nil
        let worker = Task.detached(priority: .utility) { [weak self] in
            _ = await previous?.value
            return Self.analyze(in: interval) { done, total in
                Task { @MainActor in
                    guard let self, self.generation == generation, self.isScanning else { return }
                    self.state = .scanning(done: done, total: total)
                }
            }
        }
        self.worker = worker
        Task { [weak self] in
            let result = await worker.value
            guard let self, !worker.isCancelled, self.generation == generation else { return }
            self.similar = result.similar
            self.duplicates = result.duplicates
            self.bursts = result.bursts
            self.blurry = result.blurry
            self.oldScreenshots = result.oldScreenshots
            self.videoDuplicates = result.videoDuplicates
            self.heavyVideos = result.heavyVideos
            self.unavailable = result.unavailable
            self.state = .finished
        }
    }

    func cancel() {
        generation += 1
        worker?.cancel()
        if let worker { cancelledWorker = worker }
        worker = nil
        state = .idle
    }

    /// Сбрасывает результаты, например после смены периода.
    func reset() {
        cancel()
        clearResults()
    }

    private func clearResults() {
        similar = []
        duplicates = []
        bursts = []
        blurry = []
        oldScreenshots = []
        videoDuplicates = []
        heavyVideos = []
        unavailable = 0
    }

    /// Убирает из результатов фото, которые уже решены (отправлены в корзину или оставлены).
    func removeHandled(_ ids: Set<String>) {
        func prune(_ groups: [AssetGroup]) -> [AssetGroup] {
            groups.compactMap { group in
                let left = group.assets.filter { !ids.contains($0.localIdentifier) }
                guard left.count > 1 else { return nil }
                return group.keeping(left)
            }
        }
        similar = prune(similar)
        duplicates = prune(duplicates)
        bursts = prune(bursts)
        videoDuplicates = prune(videoDuplicates)
        blurry.removeAll { ids.contains($0.localIdentifier) }
        oldScreenshots.removeAll { ids.contains($0.localIdentifier) }
        heavyVideos.removeAll { ids.contains($0.localIdentifier) }
    }

    /// Убирает из результатов фото, которых больше нет в медиатеке (удалены через корзину или в «Фото»).
    func dropMissing() async {
        guard state == .finished else { return }
        let groups = similar + duplicates + bursts + videoDuplicates
        let ids = groups.flatMap { $0.assets.map(\.localIdentifier) }
            + (blurry + oldScreenshots + heavyVideos).map(\.localIdentifier)
        guard !ids.isEmpty else { return }
        let missing = await Task.detached(priority: .utility) { LibraryFetcher.missingIDs(ids) }.value
        // Пока шла проверка, мог начаться новый анализ: его результатов ещё нет, трогать нечего.
        guard !missing.isEmpty, state == .finished else { return }
        removeHandled(missing)
    }

    // MARK: - Анализ

    private struct Result {
        var similar: [AssetGroup] = []
        var duplicates: [AssetGroup] = []
        var bursts: [AssetGroup] = []
        var blurry: [PHAsset] = []
        var oldScreenshots: [PHAsset] = []
        var videoDuplicates: [AssetGroup] = []
        var heavyVideos: [PHAsset] = []
        var unavailable = 0
    }

    /// Условие выборки по типу и, если задан период, по дате съёмки.
    nonisolated static func predicate(_ base: NSPredicate, in interval: DateInterval?) -> NSPredicate {
        guard let interval else { return base }
        let dates = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@",
            interval.start as NSDate, interval.end as NSDate
        )
        return NSCompoundPredicate(andPredicateWithSubpredicates: [base, dates])
    }

    nonisolated private static func analyze(in interval: DateInterval?, progress: @escaping (Int, Int) -> Void) -> Result {
        var result = Result()
        // С чистого листа: метрики прошлых запусков не используются, всё считается заново.
        let cache = MetricsCache.load(fresh: true)

        let photos = fetchAssets(of: .image, in: interval)
        let videos = fetchAssets(of: .video, in: interval)
        let total = photos.count + videos.count

        result.bursts = burstGroups(in: interval)
        result.oldScreenshots = photos.filter {
            $0.mediaSubtypes.contains(.photoScreenshot)
                && ($0.creationDate ?? .now) < Date(timeIntervalSinceNow: -screenshotAge)
        }

        let imageManager = PHImageManager.default()
        let requestOptions = makeRequestOptions()

        // Проход 1: резкость, хэш и контраст каждого фото; отпечаток Vision сразу уходит на диск.
        // Запись в кэше считается устаревшей, если фото редактировали после её создания.
        var metrics: [String: MetricsCache.Entry] = [:]
        metrics.reserveCapacity(photos.count)
        var pending: [PHAsset] = []
        for asset in photos {
            let id = asset.localIdentifier
            let modified = asset.modificationDate?.timeIntervalSince1970
            if var cached = cache[id], cached.modified == nil || cached.modified == modified {
                if cached.modified == nil {
                    // Запись из прошлой версии: запоминаем дату, пересчитывать незачем.
                    cached.modified = modified
                    cache[id] = cached
                }
                metrics[id] = cached
            } else {
                pending.append(asset)
            }
        }
        var done = photos.count - pending.count
        progress(done, total)
        for start in stride(from: 0, to: pending.count, by: batchSize) {
            if Task.isCancelled {
                cache.saveIfNeeded()
                return result
            }
            let batch = Array(pending[start..<min(start + batchSize, pending.count)])
            let computed = computeMetrics(for: batch, cache: cache)
            for (id, entry) in computed {
                metrics[id] = entry
                cache[id] = entry
            }
            result.unavailable += batch.count - computed.count
            done += batch.count
            progress(done, total)
            if start % 512 == 0 { cache.saveIfNeeded() }
        }

        // Видео: хэш кадра-обложки и размер файла.
        var videoItems: [VideoItem] = []
        var sizes: [String: Int64] = [:]
        for (index, video) in videos.enumerated() {
            if Task.isCancelled {
                cache.saveIfNeeded()
                return result
            }
            let id = video.localIdentifier
            let modified = video.modificationDate?.timeIntervalSince1970
            var entry: MetricsCache.Entry?
            if let cached = cache[id], cached.modified == nil || cached.modified == modified {
                entry = cached
            } else if let cgImage = thumbnail(of: video, side: videoThumbnailSide, manager: imageManager, options: requestOptions) {
                // Ролик изменился (например, обрезан): старая копия обложки для сравнения больше не годится.
                cache.removeFinePixels(for: id)
                let value = MetricsCache.Entry(
                    sharpness: 0,
                    hash: ImageMetrics.differenceHash(cgImage),
                    modified: modified,
                    contrast: ImageMetrics.contrast(cgImage)
                )
                cache[id] = value
                entry = value
            }
            if let entry, entry.hash != 0 {
                videoItems.append(VideoItem(id: id, duration: video.duration, hash: entry.hash, contrast: entry.contrast))
            }
            sizes[id] = video.cachedFileSize
            if index % 25 == 0 { progress(photos.count + index, total) }
        }
        if interval == nil {
            // Полный проход знает все ассеты: записи об удалённых фото больше не нужны.
            cache.prune(keeping: Set(photos.map(\.localIdentifier)).union(videos.map(\.localIdentifier)))
        }
        cache.saveIfNeeded()
        FileSizeCache.shared.save()
        progress(total, total)

        let videosByID = Dictionary(videos.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let photosByID = Dictionary(photos.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        // Копия 64×64 для попиксельного сравнения: с диска, а если её нет — по превью 300 точек.
        // Считается только для кандидатов в дубли, поэтому на диске таких файлов немного.
        func finePixels(_ id: String) -> [UInt8]? {
            if let stored = cache.finePixels(for: id) { return stored }
            guard let asset = photosByID[id] ?? videosByID[id],
                  let image = thumbnail(of: asset, side: photoThumbnailSide, manager: imageManager, options: requestOptions),
                  let pixels = ImageMetrics.fineSignature(image)
            else { return nil }
            cache.storeFinePixels(pixels, for: id)
            return pixels
        }
        result.videoDuplicates = videoDuplicateClusters(videoItems, pixels: finePixels).compactMap { ids -> AssetGroup? in
            let assets = ids.compactMap { videosByID[$0] }
            guard assets.count > 1 else { return nil }
            // Лучшим считаем избранное, иначе самое большое (обычно лучшее качество).
            let best = assets.first(where: \.isFavorite) ?? assets.max { (sizes[$0.localIdentifier] ?? 0) < (sizes[$1.localIdentifier] ?? 0) }
            return AssetGroup(assets: assets, bestID: (best ?? assets[0]).localIdentifier)
        }
        result.heavyVideos = videos
            .filter { (sizes[$0.localIdentifier] ?? 0) >= heavyVideoSize }
            .sorted { (sizes[$0.localIdentifier] ?? 0) > (sizes[$1.localIdentifier] ?? 0) }

        // Дубликаты: почти одинаковый хэш, те же пропорции, не однотонный кадр, те же цвета и попиксельное совпадение.
        let photoItems = photos.compactMap { asset -> PhotoItem? in
            guard let entry = metrics[asset.localIdentifier] else { return nil }
            return PhotoItem(
                id: asset.localIdentifier,
                hash: entry.hash,
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                contrast: entry.contrast,
                colors: entry.colors,
                isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)
            )
        }
        // Контраста и цветов нет у записей прошлых версий: досчитываем их по требованию одним превью.
        func completeEntry(_ id: String) -> MetricsCache.Entry? {
            if let entry = metrics[id], entry.contrast != nil, entry.colors != nil { return entry }
            guard var entry = metrics[id] ?? cache[id], let asset = photosByID[id],
                  let image = thumbnail(of: asset, side: photoThumbnailSide, manager: imageManager, options: requestOptions)
            else { return nil }
            entry.contrast = ImageMetrics.contrast(image)
            entry.colors = ImageMetrics.colorSignature(image)
            metrics[id] = entry
            cache[id] = entry
            return entry
        }
        let clusters = duplicateClusters(
            photoItems,
            contrast: { completeEntry($0)?.contrast },
            colors: { completeEntry($0)?.colors },
            pixels: finePixels
        )
        cache.saveIfNeeded()
        let duplicateGroups = clusters.map { $0.compactMap { photosByID[$0] } }.filter { $0.count > 1 }
        let duplicateIDs = Set(duplicateGroups.flatMap { $0.map(\.localIdentifier) })
        result.duplicates = duplicateGroups.map { assets -> AssetGroup in
            let candidates = assets.map { asset in
                DuplicateCandidate(
                    id: asset.localIdentifier,
                    isFavorite: asset.isFavorite,
                    pixels: asset.pixelWidth * asset.pixelHeight,
                    isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                    sharpness: metrics[asset.localIdentifier]?.sharpness ?? 0,
                    creationDate: asset.creationDate,
                    fileSize: asset.cachedFileSize
                )
            }
            return AssetGroup(assets: assets, bestID: bestDuplicate(among: candidates) ?? assets[0].localIdentifier)
        }
        // Группы, как и остальные категории, от новых к старым.
        result.duplicates.reverse()
        FileSizeCache.shared.save()

        // Проход 2, похожие: соседние по времени кадры с близкими отпечатками.
        // Скриншоты сюда не попадают: соседние экраны одного приложения похожи для Vision, но не взаимозаменяемы.
        // Отпечатки читаются с диска по мере надобности, в памяти держатся только отпечатки текущей цепочки.
        var prints: [String: VNFeaturePrintObservation] = [:]
        func loadPrint(for id: String) -> VNFeaturePrintObservation? {
            if let known = prints[id] { return known }
            let loaded = cache.featurePrint(for: id)
            prints[id] = loaded
            return loaded
        }
        let similarItems = photos.compactMap { asset -> SimilarItem? in
            guard !duplicateIDs.contains(asset.localIdentifier),
                  !asset.mediaSubtypes.contains(.photoScreenshot),
                  let date = asset.creationDate
            else { return nil }
            return SimilarItem(id: asset.localIdentifier, date: date)
        }
        let chains = similarChains(
            similarItems,
            distance: { a, b in
                guard let printA = loadPrint(for: a), let printB = loadPrint(for: b) else { return nil }
                return ImageMetrics.distance(printA, printB)
            },
            chainEnded: { ids in prints = prints.filter { !ids.contains($0.key) } }
        )
        if Task.isCancelled { return result }
        result.similar = chains.compactMap { ids -> AssetGroup? in
            let assets = ids.compactMap { photosByID[$0] }
            guard assets.count > 1 else { return nil }
            return AssetGroup(assets: assets, bestID: best(in: assets, metrics: metrics))
        }
        result.similar.reverse()

        // Однотонный кадр формально нерезкий, но размытым фото его не назовёшь.
        // Портретный режим размывает фон намеренно, такие кадры тоже не предлагаем.
        result.blurry = photos.filter {
            !$0.mediaSubtypes.contains(.photoScreenshot)
                && !$0.mediaSubtypes.contains(.photoDepthEffect)
                && (metrics[$0.localIdentifier]?.sharpness ?? .infinity) < blurThreshold
                && (completeEntry($0.localIdentifier)?.contrast ?? 0) >= duplicateMinContrast
        }.reversed()
        // Черновик больше не нужен: следующий запуск всё равно начнёт с нуля, а место на диске освободится.
        MetricsCache.clear()

        return result
    }

    nonisolated private static func fetchAssets(of mediaType: PHAssetMediaType, in interval: DateInterval?) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = predicate(NSPredicate(format: "mediaType == %d", mediaType.rawValue), in: interval)
        var assets: [PHAsset] = []
        let fetch = PHAsset.fetchAssets(with: options)
        assets.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// Настройки синхронного запроса превью. Объект изменяемый, поэтому каждому потоку нужен свой.
    nonisolated private static func makeRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return options
    }

    /// Синхронно запрашивает уменьшенную копию без обращения к iCloud.
    nonisolated private static func thumbnail(
        of asset: PHAsset,
        side: CGFloat,
        manager: PHImageManager,
        options: PHImageRequestOptions
    ) -> CGImage? {
        var cgImage: CGImage?
        manager.requestImage(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            cgImage = image.flatMap(ImageMetrics.uprightCGImage)
        }
        return cgImage
    }

    /// Метрики фото для поиска дубликатов.
    struct PhotoItem {
        let id: String
        let hash: UInt64
        let width: Int
        let height: Int
        let contrast: Double?
        var colors: [UInt8]? = nil
        var isScreenshot = false
        /// Яркость 64×64 для попиксельного сравнения; если её нет, она запрашивается по требованию.
        var pixels: [UInt8]? = nil
    }

    /// Что известно о кадре в группе дубликатов, чтобы выбрать, какой оставить.
    struct DuplicateCandidate {
        let id: String
        var isFavorite = false
        var pixels = 0
        var isLivePhoto = false
        var sharpness = 0.0
        var creationDate: Date? = nil
        var fileSize: Int64 = 0
    }

    /// Какой из дубликатов оставить: избранное, затем большее разрешение (копии из мессенджеров
    /// пережаты и меньше), затем Live Photo (в нём больше данных), затем заметно более резкий,
    /// затем более ранний (оригинал старше своей копии), затем больший файл.
    nonisolated static func bestDuplicate(among candidates: [DuplicateCandidate]) -> String? {
        candidates.max { a, b in
            if a.isFavorite != b.isFavorite { return !a.isFavorite }
            if a.pixels != b.pixels { return a.pixels < b.pixels }
            if a.isLivePhoto != b.isLivePhoto { return !a.isLivePhoto }
            let sharper = max(a.sharpness, b.sharpness)
            if sharper > 0, abs(a.sharpness - b.sharpness) / sharper > 0.05 { return a.sharpness < b.sharpness }
            switch (a.creationDate, b.creationDate) {
            case let (x?, y?) where x != y: return x > y
            case (nil, .some): return true
            case (.some, nil): return false
            default: break
            }
            return a.fileSize < b.fileSize
        }?.id
    }

    /// Фото для поиска похожих: только дата, отпечатки запрашиваются по идентификатору.
    struct SimilarItem {
        let id: String
        let date: Date
    }

    /// Цепочки похожих кадров. Кадры идут по времени; новый кадр продолжает цепочку, если снят
    /// не позже `similarTimeWindow` после предыдущего и близок и к предыдущему кадру, и к первому кадру цепочки.
    /// Проверка по первому кадру не даёт цепочке «уплыть»: при панораме из 20 кадров каждый сосед похож на соседа,
    /// но первый и последний — уже разные сцены, и оставлять один кадр из всех было бы ошибкой.
    /// `chainEnded` сообщает идентификаторы закрытой цепочки, чтобы вызывающий код освободил их отпечатки.
    nonisolated static func similarChains(
        _ items: [SimilarItem],
        distance: (String, String) -> Float?,
        chainEnded: ([String]) -> Void = { _ in }
    ) -> [[String]] {
        var chains: [[String]] = []
        var current: [SimilarItem] = []
        func flush() {
            guard !current.isEmpty else { return }
            if current.count > 1 { chains.append(current.map(\.id)) }
            chainEnded(current.map(\.id))
            current = []
        }
        for item in items {
            if Task.isCancelled { break }
            guard let last = current.last, let first = current.first,
                  item.date.timeIntervalSince(last.date) <= similarTimeWindow,
                  let toLast = distance(last.id, item.id), toLast <= similarDistance,
                  first.id == last.id || (distance(first.id, item.id) ?? .infinity) <= similarDistance
            else {
                flush()
                current = [item]
                continue
            }
            current.append(item)
        }
        flush()
        return chains
    }

    /// Группы дубликатов. Кандидаты ищутся по совпадению одной из четырёх 16-битных частей хэша:
    /// если хэши отличаются не больше чем на 3 бита, хотя бы одна часть совпадает целиком.
    /// Так не нужно сравнивать каждое фото с каждым. Пару подтверждает только попиксельное совпадение:
    /// без копии 64×64 (например, оригинал только в iCloud) фото дублем не считается.
    nonisolated static func duplicateClusters(
        _ items: [PhotoItem],
        contrast resolveContrast: @escaping (String) -> Double? = { _ in nil },
        colors resolveColors: @escaping (String) -> [UInt8]? = { _ in nil },
        pixels resolvePixels: @escaping (String) -> [UInt8]? = { _ in nil }
    ) -> [[String]] {
        let items = items.filter { $0.hash != 0 }
        guard items.count > 1 else { return [] }

        var parent = Array(items.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }

        var contrasts: [Int: Double] = [:]
        func isTextured(_ i: Int) -> Bool {
            if let known = contrasts[i] { return known >= duplicateMinContrast }
            let value = items[i].contrast ?? resolveContrast(items[i].id) ?? 0
            contrasts[i] = value
            return value >= duplicateMinContrast
        }

        var colorCache: [Int: [UInt8]] = [:]
        func colors(_ k: Int) -> [UInt8]? {
            if let known = colorCache[k] { return known }
            let value = items[k].colors ?? resolveColors(items[k].id)
            colorCache[k] = value
            return value
        }
        func sameColors(_ i: Int, _ j: Int) -> Bool {
            // Если цвета узнать нельзя (старые тесты, нет превью), решает остальная проверка.
            guard let a = colors(i), let b = colors(j) else { return true }
            let tolerance = items[i].isScreenshot && items[j].isScreenshot ? screenshotColorTolerance : duplicateColorTolerance
            return ImageMetrics.colorDifference(a, b) <= tolerance
        }

        func sameHash(_ i: Int, _ j: Int) -> Bool {
            let tolerance = items[i].isScreenshot && items[j].isScreenshot ? 0 : duplicateHashTolerance
            return ImageMetrics.hammingDistance(items[i].hash, items[j].hash) <= tolerance
        }
        var pixelCache: [Int: [UInt8]?] = [:]
        func pixels(_ k: Int) -> [UInt8]? {
            if let known = pixelCache[k] { return known }
            let value = items[k].pixels ?? resolvePixels(items[k].id)
            pixelCache[k] = value
            return value
        }
        func samePicture(_ i: Int, _ j: Int) -> Bool {
            guard let a = pixels(i), let b = pixels(j) else { return false }
            return isSamePicture(a, b, screenshots: items[i].isScreenshot && items[j].isScreenshot)
        }

        func sameShape(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
            guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return true }
            let lhs = Double(a.width) * Double(b.height)
            let rhs = Double(b.width) * Double(a.height)
            return abs(lhs - rhs) <= 0.01 * max(lhs, rhs)
        }

        for chunk in 0..<4 {
            var buckets: [UInt16: [Int]] = [:]
            for (index, item) in items.enumerated() {
                buckets[UInt16(truncatingIfNeeded: item.hash >> (chunk * 16)), default: []].append(index)
            }
            // Огромные корзины бывают только у вырожденных хэшей (однотонные кадры), их пропускаем.
            for bucket in buckets.values where bucket.count > 1 && bucket.count <= duplicateBucketLimit {
                for x in 0..<bucket.count {
                    for y in (x + 1)..<bucket.count {
                        let i = bucket[x], j = bucket[y]
                        guard find(i) != find(j),
                              sameHash(i, j),
                              sameShape(items[i], items[j]),
                              isTextured(i), isTextured(j),
                              sameColors(i, j),
                              samePicture(i, j)
                        else { continue }
                        parent[find(j)] = find(i)
                    }
                }
            }
        }

        var groups: [Int: [String]] = [:]
        var order: [Int] = []
        for index in items.indices {
            let root = find(index)
            if groups[root] == nil { order.append(root) }
            groups[root, default: []].append(items[index].id)
        }
        return order.compactMap { groups[$0] }.filter { $0.count > 1 }
    }

    /// Один ли это кадр: копии 64×64 совпадают с точностью до шума пересжатия и общего сдвига яркости.
    nonisolated static func isSamePicture(_ a: [UInt8], _ b: [UInt8], screenshots: Bool = false) -> Bool {
        let difference = ImageMetrics.fineDifference(a, b)
        if screenshots {
            return difference.mean <= screenshotMeanTolerance && difference.worstBlock <= screenshotBlockTolerance
        }
        return difference.mean <= exactMeanTolerance && difference.worstBlock <= exactBlockTolerance
    }

    /// Считает метрики пачки фото параллельно. Запросы превью и Vision потокобезопасны,
    /// отпечатки пишутся в отдельные файлы, а общий результат защищён замком.
    nonisolated private static func computeMetrics(
        for batch: [PHAsset],
        cache: MetricsCache
    ) -> [(String, MetricsCache.Entry)] {
        let collected = MetricsBatch(capacity: batch.count)
        DispatchQueue.concurrentPerform(iterations: batch.count) { index in
            let asset = batch[index]
            guard let image = thumbnail(of: asset, side: photoThumbnailSide, manager: .default(), options: makeRequestOptions()) else { return }
            let entry = MetricsCache.Entry(
                sharpness: ImageMetrics.sharpness(image),
                hash: ImageMetrics.differenceHash(image),
                modified: asset.modificationDate?.timeIntervalSince1970,
                contrast: ImageMetrics.contrast(image),
                colors: ImageMetrics.colorSignature(image)
            )
            if let observation = ImageMetrics.featurePrint(image) {
                cache.storeFeaturePrint(observation, for: asset.localIdentifier)
            }
            // Фото новое или его отредактировали: старая копия для попиксельного сравнения устарела.
            cache.removeFinePixels(for: asset.localIdentifier)
            collected.append((asset.localIdentifier, entry))
        }
        return collected.values
    }

    struct VideoItem {
        let id: String
        let duration: TimeInterval
        let hash: UInt64
        /// Контраст кадра-обложки; `nil` у записей прошлых версий кэша.
        var contrast: Double? = nil
    }

    /// Группы копий одного видео: близкая длительность, почти тот же хэш обложки и попиксельно та же обложка.
    /// Видео с тёмной или однотонной обложкой (съёмка начинается с чёрного кадра) не сравниваются:
    /// хэш такого кадра — шум, и два разных ролика одной длины склеились бы в «дубли».
    nonisolated static func videoDuplicateClusters(
        _ items: [VideoItem],
        pixels resolvePixels: (String) -> [UInt8]? = { _ in nil }
    ) -> [[String]] {
        var clusters: [[VideoItem]] = []
        var pixelCache: [String: [UInt8]?] = [:]
        func pixels(_ id: String) -> [UInt8]? {
            if let known = pixelCache[id] { return known }
            let value = resolvePixels(id)
            pixelCache[id] = value
            return value
        }
        let textured = items.filter { ($0.contrast ?? duplicateMinContrast) >= duplicateMinContrast }
        for item in textured.sorted(by: { $0.duration < $1.duration }) {
            let match = clusters.lastIndex { cluster in
                let first = cluster[0]
                guard abs(first.duration - item.duration) <= videoDurationTolerance,
                      ImageMetrics.hammingDistance(first.hash, item.hash) <= videoHashTolerance,
                      let a = pixels(first.id), let b = pixels(item.id)
                else { return false }
                return isSamePicture(a, b)
            }
            if let match {
                clusters[match].append(item)
            } else {
                clusters.append([item])
            }
        }
        return clusters.filter { $0.count > 1 }.map { $0.map(\.id) }
    }

    nonisolated private static func burstGroups(in interval: DateInterval?) -> [AssetGroup] {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = predicate(NSPredicate(format: "burstIdentifier != nil"), in: interval)
        let fetch = PHAsset.fetchAssets(with: .image, options: options)
        var groups: [String: [PHAsset]] = [:]
        var order: [String] = []
        fetch.enumerateObjects { asset, _, _ in
            guard let id = asset.burstIdentifier else { return }
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(asset)
        }
        return order.compactMap { id in
            guard let assets = groups[id], assets.count > 1 else { return nil }
            // Все кадры, которые пользователь сам отметил в серии, остаются; звезда у первого из них.
            let userPicks = assets.filter { $0.burstSelectionTypes.contains(.userPick) }
            let pick = userPicks.first
                ?? assets.first { $0.representsBurst }
                ?? assets.first { $0.burstSelectionTypes.contains(.autoPick) }
                ?? assets[0]
            let keep = Set(userPicks.map(\.localIdentifier)).union([pick.localIdentifier])
            return AssetGroup(assets: assets, bestID: pick.localIdentifier, keepIDs: keep)
        }
    }

    /// Лучший кадр группы: избранное, затем самый резкий.
    nonisolated private static func best(in assets: [PHAsset], metrics: [String: MetricsCache.Entry]) -> String {
        if let favorite = assets.first(where: \.isFavorite) { return favorite.localIdentifier }
        let sharpest = assets.max { (metrics[$0.localIdentifier]?.sharpness ?? 0) < (metrics[$1.localIdentifier]?.sharpness ?? 0) }
        return (sharpest ?? assets[0]).localIdentifier
    }
}

struct AssetGroup: Identifiable {
    let assets: [PHAsset]
    /// Кадр со звездой: лучший в группе.
    let bestID: String
    /// Какие кадры предлагается оставить. Обычно это только лучший, но в серии их может быть несколько,
    /// если пользователь сам отметил несколько кадров.
    let keepIDs: Set<String>
    /// Идентификатор задаётся при создании и не меняется, когда часть фото разобрали в другом месте,
    /// иначе экран группы терял бы выбор пользователя.
    let id: String

    init(assets: [PHAsset], bestID: String, keepIDs: Set<String>? = nil, id: String? = nil) {
        self.assets = assets
        self.bestID = bestID
        self.keepIDs = keepIDs ?? [bestID]
        self.id = id ?? assets.first?.localIdentifier ?? bestID
    }

    var others: [PHAsset] { assets.filter { !keepIDs.contains($0.localIdentifier) } }

    /// Группа из оставшихся фото. Если ушёл кадр, который предлагалось оставить (например, его разобрали
    /// в «Сериях»), выбирается новый: иначе группа предлагала бы «оставить 0» и целиком ушла бы в корзину.
    func keeping(_ left: [PHAsset]) -> AssetGroup {
        let leftIDs = Set(left.map(\.localIdentifier))
        var keep = keepIDs.intersection(leftIDs)
        var best = bestID
        if !leftIDs.contains(best) {
            let replacement = left.first { keep.contains($0.localIdentifier) }
                ?? left.first(where: \.isFavorite)
                ?? left.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
            best = (replacement ?? left[0]).localIdentifier
        }
        if keep.isEmpty { keep = [best] }
        return AssetGroup(assets: left, bestID: best, keepIDs: keep, id: id)
    }
}

/// Потокобезопасный сборщик результатов параллельного прохода.
private final class MetricsBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(String, MetricsCache.Entry)]

    init(capacity: Int) {
        storage = []
        storage.reserveCapacity(capacity)
    }

    func append(_ value: (String, MetricsCache.Entry)) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [(String, MetricsCache.Entry)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Черновик умной чистки в Caches: резкость и хэши в `smart-clean-metrics.plist`,
/// отпечатки Vision по одному файлу на ассет в `smart-clean-prints/`.
/// Так plist остаётся маленьким, а отпечатки не занимают память, пока не нужны.
/// Анализ открывает его с `fresh: true`, поэтому данные прошлых запусков не используются.
final class MetricsCache: @unchecked Sendable {
    struct Entry: Codable {
        var sharpness: Double
        var hash: UInt64
        /// Дата изменения фото на момент расчёта: если фото отредактировали, запись пересчитывается.
        var modified: TimeInterval?
        /// Контраст превью; у записей из прошлых версий его нет.
        var contrast: Double?
        /// Цветовая подпись превью (сетка 4×4, RGB); у записей из прошлых версий её нет.
        var colors: [UInt8]?
    }

    private(set) var entries: [String: Entry]
    private var isDirty = false

    private init(entries: [String: Entry]) {
        self.entries = entries
    }

    private static var cachesURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    private static var metricsURL: URL {
        cachesURL.appendingPathComponent("smart-clean-metrics.plist")
    }

    private static var printsURL: URL {
        cachesURL.appendingPathComponent("smart-clean-prints", isDirectory: true)
    }

    /// Файл старого формата, где отпечатки лежали внутри plist и он разрастался до сотен мегабайт.
    private static var legacyURL: URL {
        cachesURL.appendingPathComponent("smart-clean.plist")
    }

    /// Версия формата: ревизия отпечатков Vision и набор метрик. При смене версии кэш считается заново,
    /// иначе отпечатки другой ревизии не сравнивались бы, а записи без контраста и цветов остались бы навсегда.
    static let formatVersion = "2-rev\(ImageMetrics.featurePrintRevision)"

    private static var versionURL: URL {
        cachesURL.appendingPathComponent("smart-clean-version.txt")
    }

    /// `fresh` стирает всё, что осталось от прошлых запусков.
    static func load(fresh: Bool = false) -> MetricsCache {
        try? FileManager.default.removeItem(at: legacyURL)
        let storedVersion = (try? String(contentsOf: versionURL, encoding: .utf8)) ?? ""
        if fresh || storedVersion != formatVersion {
            clear()
            try? formatVersion.write(to: versionURL, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.createDirectory(at: printsURL, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: metricsURL),
              let entries = try? PropertyListDecoder().decode([String: Entry].self, from: data)
        else { return MetricsCache(entries: [:]) }
        return MetricsCache(entries: entries)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: legacyURL)
        try? FileManager.default.removeItem(at: metricsURL)
        try? FileManager.default.removeItem(at: printsURL)
        try? FileManager.default.removeItem(at: versionURL)
    }

    subscript(id: String) -> Entry? {
        get { entries[id] }
        set {
            entries[id] = newValue
            isDirty = true
        }
    }

    func featurePrint(for id: String) -> VNFeaturePrintObservation? {
        guard let data = try? Data(contentsOf: Self.printURL(for: id)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    func storeFeaturePrint(_ observation: VNFeaturePrintObservation, for id: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true) else { return }
        let url = Self.printURL(for: id)
        if (try? data.write(to: url, options: .atomic)) == nil {
            // Папку могли удалить кнопкой «Очистить кэш» прямо во время анализа.
            try? FileManager.default.createDirectory(at: Self.printsURL, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Копия 64×64 для попиксельного сравнения дублей. Лежит рядом с отпечатком, считается только для кандидатов.
    func finePixels(for id: String) -> [UInt8]? {
        guard let data = try? Data(contentsOf: Self.fineURL(for: id)),
              data.count == ImageMetrics.fineSide * ImageMetrics.fineSide
        else { return nil }
        return [UInt8](data)
    }

    func storeFinePixels(_ pixels: [UInt8], for id: String) {
        let data = Data(pixels)
        let url = Self.fineURL(for: id)
        if (try? data.write(to: url, options: .atomic)) == nil {
            try? FileManager.default.createDirectory(at: Self.printsURL, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func removeFinePixels(for id: String) {
        try? FileManager.default.removeItem(at: Self.fineURL(for: id))
    }

    /// Убирает записи, отпечатки и копии для сравнения у ассетов, которых больше нет в медиатеке.
    func prune(keeping ids: Set<String>) {
        let stale = entries.keys.filter { !ids.contains($0) }
        guard !stale.isEmpty else { return }
        for id in stale {
            entries[id] = nil
            try? FileManager.default.removeItem(at: Self.printURL(for: id))
            removeFinePixels(for: id)
        }
        isDirty = true
    }

    /// Пишет plist, только если что-то изменилось с прошлого сохранения.
    func saveIfNeeded() {
        guard isDirty else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: Self.metricsURL, options: .atomic)
        isDirty = false
    }

    private static func printURL(for id: String) -> URL {
        printsURL.appendingPathComponent(fileName(for: id)).appendingPathExtension("vnprint")
    }

    private static func fineURL(for id: String) -> URL {
        printsURL.appendingPathComponent(fileName(for: id)).appendingPathExtension("fine")
    }

    /// В localIdentifier есть «/», в имени файла он недопустим.
    private static func fileName(for id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
    }
}
