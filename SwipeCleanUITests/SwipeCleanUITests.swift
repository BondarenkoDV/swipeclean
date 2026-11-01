import XCTest

/// Сквозные сценарии на симуляторе: каждый идёт через настоящий PhotoKit, поэтому ловит то,
/// чего не видят модульные тесты (падения из-за изоляции акторов, системные окна, пустые состояния).
///
/// Медиатеку симулятора нужно заранее наполнить фото и видео (`scripts/seed-simulator.sh`),
/// иначе сценарии, которым нужны фото, пропускаются. Приложение запускается с `-uiTesting`:
/// хранилище в памяти и чистые настройки, настоящий прогресс не трогается.
/// Удаление в тестах настоящее: каждый прогон удаляет из медиатеки симулятора одно фото.
@MainActor
final class SwipeCleanUITests: XCTestCase {
    // MARK: - Разбор свайпами

    func testSwipeDecisionsUndoAndFullScreen() throws {
        let app = launch()
        try openSource(app, "all")

        // Счётчик «Освободится» растёт после свайпа в корзину.
        let freed = element(app, "deck.freed")
        let before = freed.label
        swipeCard(app, dx: -320, dy: 0)
        waitForPosition(app, 2)
        let grown = NSPredicate(format: "label != %@", before)
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: grown, object: freed)], timeout: 5), .completed,
                       "Счётчик не изменился после свайпа в корзину: \(freed.label)")
        swipeCard(app, dx: 320, dy: 0)
        waitForPosition(app, 3)
        swipeCard(app, dx: 0, dy: 380)
        waitForPosition(app, 4)
        app.buttons["deck.favorite"].tap()
        waitForPosition(app, 5)

        app.buttons["deck.undo"].tap()
        waitForPosition(app, 4)
        app.buttons["deck.undo"].tap()
        waitForPosition(app, 3)

        // Решение кнопкой и сразу отмена: позиция возвращается на то же фото.
        app.buttons["deck.trash"].tap()
        app.buttons["deck.undo"].tap()
        waitForPosition(app, 3)

        // Тап по карточке открывает полноэкранный просмотр.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        let close = app.buttons["fullscreen.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.buttons["deck.undo"].waitForExistence(timeout: 5))
        assertRunning(app)
    }

    func testSwappedDirectionsSendLeftSwipeToKeep() throws {
        let app = launch(extra: ["-swapHorizontalSwipes", "YES"])
        try openSource(app, "all")
        swipeCard(app, dx: -320, dy: 0)
        waitForPosition(app, 2)
        app.tabBars.buttons["Корзина"].tap()
        XCTAssertTrue(app.staticTexts["Корзина пуста"].waitForExistence(timeout: 5), "Свайп влево при обмене сторон должен оставлять фото")
        assertRunning(app)
    }

    func testLaterDeckShowsPostponedPhoto() throws {
        let app = launch()
        try openSource(app, "all")
        swipeCard(app, dx: 0, dy: 380)
        waitForPosition(app, 2)
        app.navigationBars.buttons.firstMatch.tap()

        try openSource(app, "later")
        XCTAssertTrue(app.staticTexts["deck.position"].label.hasPrefix("1 из 1"), app.staticTexts["deck.position"].label)
        // Повторное «позже» оставляет фото в подборке, «оставить» завершает её.
        swipeCard(app, dx: 320, dy: 0)
        XCTAssertTrue(app.staticTexts["Готово"].waitForExistence(timeout: 5))
        let undo = app.buttons.matching(NSPredicate(format: "label == 'Вернуть последнее' AND enabled == true")).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        waitForPosition(app, 1)
        assertRunning(app)
    }

    func testEverySourceOpens() throws {
        let app = launch()
        for source in ["all", "random", "onThisDay", "videos", "screenshots", "selfies", "livePhotos", "largeFiles", "later"] {
            app.tabBars.buttons["Разбор"].tap()
            let tile = app.buttons["source.\(source)"]
            XCTAssertTrue(tile.waitForExistence(timeout: 10), source)
            tile.tap()
            let opened = waitForAny(
                [app.staticTexts["deck.position"], app.staticTexts["Здесь пусто"], app.staticTexts["Всё разобрано"]],
                timeout: 60
            )
            XCTAssertTrue(opened, "Подборка \(source) не открылась")
            app.navigationBars.buttons.firstMatch.tap()
        }
        // Первый месяц в списке тоже открывается.
        let month = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'month.'")).firstMatch
        if month.waitForExistence(timeout: 10) {
            month.tap()
            XCTAssertTrue(app.staticTexts["deck.position"].waitForExistence(timeout: 10))
        }
        assertRunning(app)
    }

    func testVideoCardPlaysInFullScreen() throws {
        let app = launch()
        try openSource(app, "videos")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        let close = app.buttons["fullscreen.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        sleep(2)
        close.tap()
        swipeCard(app, dx: 320, dy: 0)
        assertRunning(app)
    }

    // MARK: - Избранное и альбомы

    func testFavoriteAndPinnedAlbum() throws {
        let app = launch()
        try openSource(app, "all")
        app.buttons["deck.favorite"].tap()
        waitForPosition(app, 2)

        app.buttons["Альбомы"].tap()
        app.buttons["Новый"].tap()
        let name = "Тест \(Int(Date().timeIntervalSince1970) % 100_000)"
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.alerts.buttons["Создать"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10), "Новый альбом не появился в списке")
        app.buttons["Готово"].tap()

        let pinned = app.buttons[name]
        XCTAssertTrue(pinned.waitForExistence(timeout: 10), "Новый альбом не закрепился на панели")
        pinned.tap()
        waitForPosition(app, 3)

        app.buttons["deck.undo"].tap()
        waitForPosition(app, 2)
        app.buttons["deck.undo"].tap()
        waitForPosition(app, 1)
        assertRunning(app)
    }

    // MARK: - Корзина

    func testTrashCancelRestoreAndDelete() throws {
        let app = launch()
        try openSource(app, "all")
        app.buttons["deck.trash"].tap()
        waitForPosition(app, 2)
        app.buttons["deck.trash"].tap()
        waitForPosition(app, 3)

        app.tabBars.buttons["Корзина"].tap()
        let items = app.buttons.matching(identifier: "trash.item")
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(items.count, 2)

        // Тап без режима выбора открывает фото.
        items.firstMatch.tap()
        let close = app.buttons["fullscreen.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()

        // Отказ в системном окне: ни ошибки, ни удаления.
        let delete = app.buttons["trash.delete"]
        delete.tap()
        XCTAssertTrue(tapSystemButton(app, ["Don’t Allow", "Don't Allow", "Не разрешать", "Cancel", "Отменить"]), "Не появилось системное подтверждение удаления")
        XCTAssertFalse(app.alerts["Не удалось удалить"].waitForExistence(timeout: 2), "Отмена показана как ошибка")
        XCTAssertEqual(items.count, 2)

        // Одно фото возвращаем через режим выбора.
        app.buttons["Выбрать"].tap()
        items.firstMatch.tap()
        app.buttons["trash.restore"].tap()
        XCTAssertTrue(waitForCount(items, 1))

        // Второе удаляем по-настоящему: именно здесь раньше падало «Удалить всё».
        app.buttons["Готово"].tap()
        delete.tap()
        XCTAssertTrue(tapSystemButton(app, ["Delete", "Удалить"]), "Не появилось системное подтверждение удаления")
        XCTAssertTrue(app.staticTexts["Корзина пуста"].waitForExistence(timeout: 10))
        assertRunning(app)
    }

    // MARK: - Умная чистка

    func testSmartCleanScanCategoriesAndPeriod() throws {
        let app = launch()
        try requirePhotos(app)
        app.tabBars.buttons["Главная"].tap()
        element(app, "home.smartClean").tap()

        // Отмена посреди анализа возвращает к началу.
        app.buttons["smart.scan"].tap()
        let cancel = app.buttons["Отмена"]
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
            XCTAssertTrue(app.buttons["smart.scan"].waitForExistence(timeout: 10))
        }

        // С прогретым кэшем анализ заканчивается раньше, чем успевает появиться «Отмена»: тогда запускаем его заново.
        let scan = app.buttons["smart.scan"]
        (scan.exists ? scan : app.buttons["smart.rescan"]).tap()
        XCTAssertTrue(app.buttons["smart.rescan"].waitForExistence(timeout: 300), "Анализ не закончился")

        // Почта не подключена: умная чистка предлагает её подключить, а в плитках почта идёт первой.
        XCTAssertTrue(element(app, "smart.mailConnect").exists)
        XCTAssertTrue(element(app, "smart.mailTile").exists)

        for category in ["similar", "duplicates", "bursts", "videoDuplicates"] {
            element(app, "smart.\(category)").tap()
            let applyAll = app.buttons["groups.applyAll"]
            if applyAll.waitForExistence(timeout: 3) {
                applyAll.tap()
                XCTAssertTrue(app.staticTexts["Ничего не найдено"].waitForExistence(timeout: 5), category)
            }
            app.navigationBars.buttons.firstMatch.tap()
        }
        for category in ["blurry", "screenshots", "heavyVideos"] {
            element(app, "smart.\(category)").tap()
            let toggleAll = app.buttons["selection.toggleAll"]
            if toggleAll.waitForExistence(timeout: 3), toggleAll.isEnabled {
                toggleAll.tap()
                app.buttons["selection.trash"].tap()
                XCTAssertTrue(app.staticTexts["Пусто"].waitForExistence(timeout: 5), category)
            }
            app.navigationBars.buttons.firstMatch.tap()
        }

        // Смена периода сбрасывает результаты, «Всё время» возвращает весь диапазон.
        element(app, "smart.period").tap()
        app.buttons["Предыдущий год"].tap()
        app.buttons.matching(identifier: "period.cell").firstMatch.tap()
        app.buttons["Готово"].tap()
        XCTAssertTrue(app.buttons["smart.scan"].waitForExistence(timeout: 5))
        element(app, "smart.period").tap()
        app.buttons["Всё время"].tap()
        app.buttons["Готово"].tap()
        assertRunning(app)
    }

    // MARK: - Главная и инструменты

    func testHomeShowsStorageAndOpensSwipes() throws {
        let app = launch()
        app.tabBars.buttons["Главная"].tap()
        XCTAssertTrue(element(app, "home.storage").label.contains("Память iPhone"))

        // Период умной чистки виден и меняется прямо на главной, «Всё время» снимает ограничение.
        let period = element(app, "home.period")
        XCTAssertTrue(period.label.contains("Всё время"), "На главной не виден период: \(period.label)")
        period.tap()
        app.buttons["Предыдущий год"].tap()
        app.buttons.matching(identifier: "period.cell").firstMatch.tap()
        app.buttons["Готово"].tap()
        XCTAssertFalse(element(app, "home.period").label.contains("Всё время"), "Период на главной не сменился")
        element(app, "home.period").tap()
        app.buttons["Всё время"].tap()
        app.buttons["Готово"].tap()
        XCTAssertTrue(element(app, "home.period").label.contains("Всё время"))
        element(app, "home.swipe").tap()
        XCTAssertTrue(app.buttons["source.all"].waitForExistence(timeout: 5), "Кнопка свайпов не открыла «Разбор»")
        assertRunning(app)
    }

    /// Карточка памяти открывает разбивку: разделы фото и видео с размерами, почта iCloud, SwipeClean и остальное.
    /// Раздел открывает свои фото, самые тяжёлые первыми.
    func testStorageBreakdownOpensKinds() throws {
        let app = launch(extra: ["-seedMail"])
        try requirePhotos(app)
        app.tabBars.buttons["Главная"].tap()
        attachScreenshot(app, "home")
        element(app, "home.storage").tap()
        XCTAssertTrue(element(app, "storage.overview").label.contains("Занято"))

        // Разделы появляются, когда посчитаны размеры: в тестовой медиатеке есть и фото, и видео.
        let photos = app.buttons["storage.kind.photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 60), "Нет раздела «Фото»")
        // Ролики тестовой медиатеки взяты из заставок macOS, в них 240 кадров/с: Фото считает их замедленными.
        let videoKinds = ["storage.kind.videos", "storage.kind.slowMotion", "storage.kind.timelapses"]
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier IN %@", videoKinds)).firstMatch.exists, "Нет раздела с видео")
        XCTAssertTrue(photos.label.contains("фото"), photos.label)
        attachScreenshot(app, "storage-top")

        // Строка легенды выделяет свою долю круга, повторное нажатие снимает выделение.
        let free = app.buttons["storage.legend.free"]
        XCTAssertTrue(free.exists, "В легенде нет свободного места")
        free.tap()
        attachScreenshot(app, "storage-selected")
        free.tap()

        photos.tap()
        XCTAssertTrue(app.buttons["selection.toggleAll"].waitForExistence(timeout: 30), "Сетка раздела не открылась")
        XCTAssertTrue(app.navigationBars["Фото"].exists)
        attachScreenshot(app, "storage-photos")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Почта из тестового ящика: размер по данным сервера приходит без проверки писем.
        let mail = app.buttons["storage.mail"]
        scrollTo(mail, in: app)
        let quota = NSPredicate(format: "label CONTAINS %@", "По данным сервера")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: quota, object: mail)], timeout: 15), .completed, mail.label)

        let other = element(app, "storage.other")
        scrollTo(other, in: app)
        XCTAssertTrue(other.label.contains("Приложения и система"), other.label)
        XCTAssertTrue(element(app, "storage.app").label.contains("SwipeClean"))
        attachScreenshot(app, "storage-bottom")

        // Плитка внизу ведёт в сжатие.
        let compress = app.buttons["storage.compress"]
        scrollTo(compress, in: app)
        compress.tap()
        XCTAssertTrue(element(app, "compress.kind").waitForExistence(timeout: 10), "Сжатие не открылось")
        assertRunning(app)
    }

    /// Раздел открывается из легенды диаграммы: сводка и группы по размеру. Группа оставляет в сетке только свои фото,
    /// «Выбрать все» отмечает только их и показывает, сколько они весят, а после корзины группа уходит из сводки.
    func testStorageKindFiltersBySizeAndTrashes() throws {
        let app = launch()
        try requirePhotos(app)
        app.tabBars.buttons["Главная"].tap()
        element(app, "home.storage").tap()

        let legend = app.buttons["storage.legend.photos"]
        XCTAssertTrue(legend.waitForExistence(timeout: 60), "В легенде нет фото")
        legend.tap()
        let open = app.buttons["storage.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Под легендой нет перехода к фото")
        scrollTo(open, in: app)
        attachScreenshot(app, "storage-legend-open")
        open.tap()

        let summary = element(app, "kind.summary")
        XCTAssertTrue(summary.label.contains("фото"), summary.label)
        XCTAssertTrue(app.navigationBars["Фото"].exists)
        let items = app.buttons.matching(identifier: "selection.item")
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 30), "Сетка раздела не открылась")
        let selected = element(app, "selection.selectedBytes")
        XCTAssertEqual(selected.label, "Отметьте, что убрать")
        attachScreenshot(app, "kind-summary")

        // Самая лёгкая из групп: её границы известны по порогам для фото (20, 5 и 2 МБ).
        let buckets = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "kind.bucket."))
        XCTAssertGreaterThan(buckets.count, 0, "Нет групп по размеру")
        let groupCount = buckets.count
        let lightest = buckets.element(boundBy: groupCount - 1)
        let lower = Double(lightest.identifier.replacingOccurrences(of: "kind.bucket.", with: "")) ?? -1
        let upper = [20e6, 5e6, 2e6].last { $0 > lower }
        lightest.tap()
        attachScreenshot(app, "kind-bucket")
        // Размеры на клетках округлены, поэтому границы с запасом в пять процентов.
        let deadline = Date().addingTimeInterval(5)
        var outside: [Double] = []
        repeat {
            let sizes = (0..<min(items.count, 12)).compactMap { bytes(items.element(boundBy: $0)) }
            outside = sizes.filter { size in size < lower * 0.95 || upper.map { size >= $0 * 1.05 } ?? false }
            if !sizes.isEmpty, outside.isEmpty { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        XCTAssertEqual(outside, [], "В сетке фото не из группы от \(lower) до \(String(describing: upper))")

        app.buttons["selection.toggleAll"].tap()
        XCTAssertTrue(selected.label.hasPrefix("Выбрано: "), selected.label)
        app.buttons["selection.trash"].tap()
        if groupCount == 1 {
            XCTAssertTrue(app.staticTexts["Пусто"].waitForExistence(timeout: 5), "После корзины в разделе что-то осталось")
        } else {
            XCTAssertTrue(waitForDisappearance(lightest), "Группа осталась в сводке после корзины")
            XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 5), "Остальные фото раздела пропали из сетки")
            XCTAssertEqual(buckets.count, groupCount - 1)
        }
        assertRunning(app)
    }

    /// Видео в разделе памяти: размер справа внизу на каждой клетке, сначала самые тяжёлые,
    /// меню сортировки переворачивает порядок. Фото раздела и сжатие сортируются тем же меню.
    func testGridsSortBySizeAndShowSize() throws {
        let app = launch()
        try requirePhotos(app)
        app.tabBars.buttons["Главная"].tap()
        element(app, "home.storage").tap()

        let photos = app.buttons["storage.kind.photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 60), "Нет раздела «Фото»")
        let videoKinds = ["storage.kind.videos", "storage.kind.slowMotion", "storage.kind.timelapses"]
        let videos = app.buttons.matching(NSPredicate(format: "identifier IN %@", videoKinds)).firstMatch
        guard videos.exists else {
            throw XCTSkip("В медиатеке нет видео: наполните медиатеку симулятора (scripts/seed-simulator.sh)")
        }
        scrollTo(videos, in: app)
        videos.tap()

        let items = app.buttons.matching(identifier: "selection.item")
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 30), "Сетка видео не открылась")
        let first = items.firstMatch
        XCTAssertTrue(first.label.hasPrefix("Видео"), first.label)
        XCTAssertNotNil(bytes(first), "У видео не виден размер: \(String(describing: first.value))")
        assertSizes(items, descending: true)
        attachScreenshot(app, "videos-largest")
        pickSort(app, menu: "selection.sort", "Сначала маленькие")
        assertSizes(items, descending: false)
        attachScreenshot(app, "videos-smallest")
        pickSort(app, menu: "selection.sort", "Сначала новые")
        XCTAssertTrue(items.firstMatch.exists)
        pickSort(app, menu: "selection.sort", "Сначала большие")
        assertSizes(items, descending: true)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Фото раздела: их в тестовой медиатеке больше, и порядок по размеру виден на нескольких клетках.
        for _ in 0..<4 where !(photos.exists && photos.isHittable) {
            app.swipeDown()
        }
        photos.tap()
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 30), "Сетка фото не открылась")
        XCTAssertTrue(items.firstMatch.label.hasPrefix("Фото"), items.firstMatch.label)
        assertSizes(items, descending: true)
        pickSort(app, menu: "selection.sort", "Сначала маленькие")
        assertSizes(items, descending: false)
        pickSort(app, menu: "selection.sort", "Сначала большие")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Сжатие видео: размер на клетках и то же меню сортировки.
        let compress = app.buttons["storage.compress"]
        scrollTo(compress, in: app)
        compress.tap()
        let candidates = app.buttons.matching(identifier: "compress.item")
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 30), "В сжатии нет видео")
        assertSizes(candidates, descending: true)
        pickSort(app, menu: "compress.sort", "Сначала маленькие")
        assertSizes(candidates, descending: false)
        attachScreenshot(app, "compress-smallest")
        assertRunning(app)
    }

    /// Сжатие самого тяжёлого фото с удалением оригинала: число фото в медиатеке не меняется.
    func testCompressPhotoReplacesOriginal() throws {
        let app = launch()
        try requirePhotos(app)
        app.tabBars.buttons["Главная"].tap()
        let tile = app.buttons["home.compress"]
        scrollTo(tile, in: app)
        tile.tap()
        app.buttons["Фото"].tap()
        element(app, "compress.level.low").tap()
        let item = app.buttons.matching(identifier: "compress.item").firstMatch
        guard item.waitForExistence(timeout: 30) else {
            throw XCTSkip("Нет фото от 1 МБ: наполните медиатеку симулятора (scripts/seed-simulator.sh)")
        }
        item.tap()
        app.buttons["compress.start"].tap()
        XCTAssertTrue(tapSystemButton(app, Self.deleteLabels, timeout: 60), "Не появилось подтверждение удаления оригинала")
        let report = element(app, "compress.report")
        XCTAssertTrue(report.label.contains("Сэкономлено"), report.label)
        assertRunning(app)
    }

    /// Live Photos становятся обычными фото. Тестовые Live Photos приложение собирает само (`-seedLivePhotos`):
    /// симулятор их не снимает. Отказ в системном окне не меняет медиатеку совсем (копии и удаление — одна транзакция),
    /// подтверждение убирает видео, а число фото не меняется: каждое Live Photo заменено своим снимком.
    func testLivePhotosBecomeStills() throws {
        let app = launch(extra: ["-seedLivePhotos"])
        app.tabBars.buttons["Главная"].tap()
        let tile = app.buttons["home.livePhotos"]
        scrollTo(tile, in: app)
        tile.tap()

        let items = app.buttons.matching(identifier: "live.item")
        guard items.firstMatch.waitForExistence(timeout: 60) else {
            let error = app.staticTexts["live.seedError"]
            XCTFail(error.exists ? error.label : "Нет Live Photos: тестовые не появились")
            return
        }
        let live = liveCount(app)
        XCTAssertGreaterThanOrEqual(live ?? 0, 2, element(app, "live.summary").label)
        XCTAssertEqual(items.count, live)
        XCTAssertNotNil(bytes(items.firstMatch), "На превью нет размера видео")
        attachScreenshot(app, "Live Photos")

        app.navigationBars.buttons.firstMatch.tap()
        let photos = stablePhotoCount(app)
        XCTAssertNotNil(photos, element(app, "home.storage").label)

        // Отказ в системном окне: ни копий, ни удаления.
        scrollTo(tile, in: app)
        tile.tap()
        element(app, "live.toggleAll").tap()
        app.buttons["live.start"].tap()
        XCTAssertTrue(tapSystemButton(app, ["Don’t Allow", "Don't Allow", "Не разрешать", "Cancel", "Отменить"], timeout: 60), "Не появилось системное подтверждение")
        XCTAssertTrue(element(app, "live.report").label.contains("Отменено"), element(app, "live.report").label)
        XCTAssertEqual(liveCount(app), live, "После отказа Live Photos изменились")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertEqual(stablePhotoCount(app), photos, "После отказа в медиатеке появились копии")

        // Подтверждение: все Live Photos стали обычными фото.
        scrollTo(tile, in: app)
        tile.tap()
        element(app, "live.toggleAll").tap()
        app.buttons["live.start"].tap()
        XCTAssertTrue(tapSystemButton(app, Self.deleteLabels, timeout: 60), "Не появилось системное подтверждение")
        let report = element(app, "live.report")
        XCTAssertTrue(report.label.contains("Сэкономлено"), report.label)
        let summary = element(app, "live.summary")
        let none = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'Live Photos: 0'"), object: summary)
        XCTAssertEqual(XCTWaiter().wait(for: [none], timeout: 10), .completed, summary.label)
        XCTAssertTrue(element(app, "live.empty").exists)
        attachScreenshot(app, "Live Photos: готово")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertEqual(stablePhotoCount(app), photos, "Число фото изменилось: снимки не заменили Live Photos один к одному")
        assertRunning(app)
    }

    func testVaultPasscodeImportAndRestore() throws {
        let app = launch()
        try requirePhotos(app)
        app.tabBars.buttons["Главная"].tap()
        let tile = app.buttons["home.vault"]
        scrollTo(tile, in: app)
        tile.tap()

        // Новый PIN-код: два одинаковых ввода.
        enterPIN(app, "1111")
        XCTAssertTrue(app.staticTexts["Повторите PIN-код"].waitForExistence(timeout: 5))
        enterPIN(app, "1111")
        XCTAssertTrue(app.buttons["vault.add"].waitForExistence(timeout: 5))

        app.buttons["vault.add"].tap()
        let pick = app.buttons.matching(identifier: "vaultPicker.item").firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 30))
        pick.tap()
        app.buttons["vaultPicker.add"].tap()
        // Оригинал удаляем, а в конце возвращаем копию: число фото в медиатеке симулятора не меняется.
        let deleteOriginals = app.buttons["vault.deleteOriginals"].firstMatch
        XCTAssertTrue(deleteOriginals.waitForExistence(timeout: 30))
        deleteOriginals.tap()
        XCTAssertTrue(tapSystemButton(app, Self.deleteLabels), "Не появилось подтверждение удаления оригинала")
        XCTAssertTrue(app.buttons.matching(identifier: "vault.item").firstMatch.waitForExistence(timeout: 10))

        // Закрытая папка не открывается чужим кодом.
        app.buttons["vault.menu"].tap()
        app.buttons["Закрыть папку"].tap()
        enterPIN(app, "2222")
        XCTAssertFalse(app.buttons["vault.add"].waitForExistence(timeout: 2))
        enterPIN(app, "1111")
        XCTAssertTrue(app.buttons["vault.add"].waitForExistence(timeout: 5))

        // Возврат в «Фото» убирает файл из папки.
        app.buttons["vault.menu"].tap()
        app.buttons["Выбрать"].tap()
        app.buttons.matching(identifier: "vault.item").firstMatch.tap()
        app.buttons["vault.restore"].tap()
        XCTAssertTrue(app.staticTexts["Папка пуста"].waitForExistence(timeout: 15))
        assertRunning(app)
    }

    func testContactsMergeDuplicatesAndDeleteEmpty() throws {
        let app = launch(extra: ["-seedContacts"])
        app.tabBars.buttons["Главная"].tap()
        let tile = app.buttons["home.contacts"]
        scrollTo(tile, in: app)
        tile.tap()
        tapSystemButton(app, Self.contactsAccessLabels, timeout: 3)

        let duplicate = app.staticTexts.matching(NSPredicate(format: "label == 'Тест Дубль'")).firstMatch
        XCTAssertTrue(duplicate.waitForExistence(timeout: 20), "Нет тестовых дублей: доступ к контактам не выдан?")
        let group = app.otherElements.matching(identifier: "contacts.group").containing(NSPredicate(format: "label == 'Тест Дубль'")).firstMatch
        (group.exists ? group.buttons["contacts.merge"] : app.buttons["contacts.merge"].firstMatch).tap()
        XCTAssertTrue(waitForCount(app.staticTexts.matching(NSPredicate(format: "label == 'Тест Дубль'")), 0, timeout: 10), "Дубли не объединились")

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Без номера'")).firstMatch.tap()
        let empty = app.buttons.matching(NSPredicate(format: "identifier == 'contacts.row' AND label CONTAINS 'Тест Без Номера'")).firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        empty.tap()
        app.buttons["contacts.delete"].tap()
        let confirm = app.buttons["contacts.confirmDelete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(waitForCount(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Тест Без Номера'")), 0, timeout: 10))
        assertRunning(app)
    }

    /// Перед объединением и удалением сохраняется копия: объединение отменяется кнопкой «Отменить»,
    /// удаление — восстановлением из «Резервных копий», полная копия делается кнопкой.
    func testContactsBackupUndoAndRestore() throws {
        let app = launch(extra: ["-seedContacts"])
        app.tabBars.buttons["Главная"].tap()
        let tile = app.buttons["home.contacts"]
        scrollTo(tile, in: app)
        tile.tap()
        tapSystemButton(app, Self.contactsAccessLabels, timeout: 3)

        let duplicates = app.staticTexts.matching(NSPredicate(format: "label == 'Тест Дубль'"))
        XCTAssertTrue(duplicates.firstMatch.waitForExistence(timeout: 20), "Нет тестовых дублей: доступ к контактам не выдан?")
        let group = app.otherElements.matching(identifier: "contacts.group").containing(NSPredicate(format: "label == 'Тест Дубль'")).firstMatch
        (group.exists ? group.buttons["contacts.merge"] : app.buttons["contacts.merge"].firstMatch).tap()
        XCTAssertTrue(waitForCount(duplicates, 0, timeout: 10), "Дубли не объединились")

        // «Отменить» возвращает удалённый при объединении контакт: группа дублей снова на экране.
        let undo = app.buttons["contacts.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Нет кнопки отмены после объединения")
        undo.tap()
        XCTAssertTrue(waitForCount(duplicates, 2, timeout: 10), "Объединение не отменилось: \(duplicates.count) «Тест Дубль»")
        XCTAssertTrue(waitForDisappearance(undo), "Плашка отмены не скрылась после восстановления")

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Без номера'")).firstMatch.tap()
        let empty = app.buttons.matching(NSPredicate(format: "identifier == 'contacts.row' AND label CONTAINS 'Тест Без Номера'"))
        XCTAssertTrue(empty.firstMatch.waitForExistence(timeout: 5))
        empty.firstMatch.tap()
        app.buttons["contacts.delete"].tap()
        let confirm = app.buttons["contacts.confirmDelete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(waitForCount(empty, 0, timeout: 10), "Контакт не удалился")

        // Удалённый контакт возвращается из копии на экране «Резервные копии».
        let backupsLink = element(app, "contacts.backups")
        backupsLink.tap()
        let items = app.otherElements.matching(identifier: "backups.item")
        XCTAssertTrue(waitForCount(items, 2, timeout: 10), "Ожидались две копии, на экране \(items.count)")
        XCTAssertTrue(app.staticTexts["Перед удалением"].exists)
        XCTAssertTrue(app.staticTexts["Перед объединением"].exists)
        let restore = app.buttons.matching(identifier: "backups.restore")
        XCTAssertEqual(restore.count, 1, "Отменённое объединение должно быть отмечено как восстановленное")
        restore.firstMatch.tap()
        let confirmRestore = app.buttons["backups.confirmRestore"].firstMatch
        XCTAssertTrue(confirmRestore.waitForExistence(timeout: 5))
        confirmRestore.tap()
        XCTAssertTrue(waitForCount(restore, 0, timeout: 10), "Копия не восстановилась")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "backups.restored").count, 2)

        app.buttons["backups.makeFull"].tap()
        XCTAssertTrue(waitForCount(items, 3, timeout: 15), "Полная копия не появилась")
        XCTAssertTrue(app.staticTexts["Все контакты"].exists)
        XCTAssertTrue(app.buttons.matching(identifier: "backups.share").firstMatch.exists)

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(empty.firstMatch.waitForExistence(timeout: 10), "Удалённый контакт не вернулся из копии")
        assertRunning(app)
    }

    func testCalendarDeletesOldEvents() throws {
        let app = launch(extra: ["-seedCalendar"])
        app.tabBars.buttons["Главная"].tap()
        let tile = app.buttons["home.calendar"]
        scrollTo(tile, in: app)
        tile.tap()
        tapSystemButton(app, Self.calendarAccessLabels, timeout: 3)

        let events = app.buttons.matching(NSPredicate(format: "identifier == 'calendar.event' AND label CONTAINS 'Тест событие'"))
        XCTAssertTrue(events.firstMatch.waitForExistence(timeout: 20), "Нет тестовых событий: доступ к календарю не выдан?")
        let count = events.count
        for index in 0..<count {
            events.element(boundBy: index).tap()
        }
        app.buttons["calendar.delete"].tap()
        let confirm = app.buttons["calendar.confirmDelete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(waitForCount(events, 0, timeout: 10), "События не удалились")
        assertRunning(app)
    }

    // MARK: - Почта iCloud и Gmail

    /// Тестовый ящик без сети: спам, удалённые, рассылки, тяжёлое и старое непрочитанное письмо.
    /// Проверяем категории, снятие письма с чистки, чистку одной кнопкой и отключение почты.
    func testMailCleanFindsAndCleansJunk() throws {
        let app = launch(extra: ["-seedMail"])
        app.tabBars.buttons["Главная"].tap()
        let tile = app.buttons["home.mail"]
        scrollTo(tile, in: app)
        tile.tap()

        // Проверка почты запускается сама: появляются категории с тестовыми письмами.
        let junk = app.buttons["mail.category.junk"]
        XCTAssertTrue(junk.waitForExistence(timeout: 15), "Категории почты не появились")
        XCTAssertTrue(junk.label.contains("3"), "В спаме должно быть 3 письма: \(junk.label)")
        XCTAssertTrue(app.buttons["mail.category.trash"].label.contains("2"))
        XCTAssertTrue(app.buttons["mail.category.newsletters"].label.contains("2"))
        XCTAssertTrue(app.buttons["mail.category.large"].exists)
        XCTAssertTrue(app.buttons["mail.category.unreadOld"].exists)

        // Список категории показывает письма текстом; нажатие только снимает письмо с чистки.
        junk.tap()
        let rows = app.buttons.matching(identifier: "mail.message")
        XCTAssertTrue(waitForCount(rows, 3, timeout: 5), "В спаме должно быть 3 письма")
        rows.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Одной кнопкой: спам (2 из 3), удалённые и рассылки. Тяжёлые и непрочитанные по умолчанию выключены.
        let clean = app.buttons["mail.clean"]
        XCTAssertTrue(clean.waitForExistence(timeout: 5))
        XCTAssertTrue(clean.label.contains("6"), "Кнопка должна считать 6 писем: \(clean.label)")
        clean.tap()
        let confirm = app.buttons["mail.confirmClean"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        let report = element(app, "mail.report")
        XCTAssertTrue(report.waitForExistence(timeout: 15), "Отчёт о чистке не появился")
        XCTAssertTrue(report.label.contains("6"), "Удалиться должны 6 писем: \(report.label)")
        XCTAssertTrue(app.buttons["mail.category.junk"].label.contains("1"), "Снятое с чистки письмо должно остаться")
        XCTAssertFalse(app.buttons["mail.category.trash"].exists)
        XCTAssertFalse(app.buttons["mail.category.newsletters"].exists)

        // Отключение убирает пароль из связки ключей и возвращает экран подключения с обоими сервисами.
        app.buttons["mail.menu"].tap()
        app.buttons["mail.disconnect.icloud"].tap()
        let confirmDisconnect = app.buttons["mail.confirmDisconnect"].firstMatch
        XCTAssertTrue(confirmDisconnect.waitForExistence(timeout: 5))
        confirmDisconnect.tap()
        XCTAssertTrue(app.buttons["mail.connect"].waitForExistence(timeout: 5), "После отключения нет кнопки подключения")
        XCTAssertTrue(element(app, "mail.connect.gmail").exists, "Нет кнопки подключения Gmail")

        // Окно подключения ведёт создавать пароль приложения у Apple.
        app.buttons["mail.connect"].tap()
        XCTAssertTrue(element(app, "mail.createPasswordLink").exists, "Нет кнопки создания пароля приложения")
        app.navigationBars.buttons["Отмена"].tap()
        assertRunning(app)
    }

    /// Письма из «Входящих» собраны по отправителям: у кого больше писем — сверху. Отправителя можно открыть,
    /// снять письмо с чистки и перенести остальное в «Удалённые», а нескольких отметить и убрать разом.
    func testMailSendersGroupAndDelete() throws {
        let app = launch(extra: ["-seedMail"])
        app.tabBars.buttons["Главная"].tap()
        let tile = app.buttons["home.mail"]
        scrollTo(tile, in: app)
        tile.tap()
        XCTAssertTrue(app.buttons["mail.category.junk"].waitForExistence(timeout: 15), "Категории почты не появились")

        // В тестовом ящике 9 писем во «Входящих» от 7 отправителей; больше всех у «Тест Магазин».
        let card = app.buttons["mail.senders"]
        scrollTo(card, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Нет карточки отправителей")
        XCTAssertTrue(card.label.contains("Тест Магазин"), card.label)
        card.tap()

        let rows = app.buttons.matching(identifier: "mail.sender")
        XCTAssertTrue(waitForCount(rows, 7), "Отправителей должно быть 7, а не \(rows.count)")
        let store = rows.element(boundBy: 0)
        XCTAssertTrue(store.label.contains("Тест Магазин") && store.label.contains("3"), store.label)

        // Письма отправителя: одно снимаем с чистки, два уходят в «Удалённые».
        store.tap()
        let messages = app.buttons.matching(identifier: "mail.message")
        XCTAssertTrue(waitForCount(messages, 3), "У отправителя должно быть 3 письма")
        messages.element(boundBy: 0).tap()
        let delete = app.buttons["mail.sender.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertTrue(delete.label.contains("2"), delete.label)
        delete.tap()
        let confirm = app.buttons["mail.sender.confirmDelete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let report = element(app, "mail.senders.report")
        XCTAssertTrue(report.label.contains("2"), "Перенестись должны 2 письма: \(report.label)")
        XCTAssertTrue(waitForCount(messages, 1), "Снятое с чистки письмо должно остаться")
        attachScreenshot(app, "Письма отправителя")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Два адреса рассылки с одним именем: отмечаем оба и убираем одной кнопкой.
        let picks = app.buttons.matching(NSPredicate(format: "identifier == 'mail.sender.pick' AND label == 'Тест Рассылка'"))
        XCTAssertTrue(waitForCount(picks, 2), "Должно быть два адреса «Тест Рассылка»")
        picks.element(boundBy: 0).tap()
        picks.element(boundBy: 1).tap()
        let deleteAll = app.buttons["mail.senders.delete"]
        XCTAssertTrue(deleteAll.waitForExistence(timeout: 5))
        XCTAssertTrue(deleteAll.label.contains("2"), deleteAll.label)
        attachScreenshot(app, "Отправители")
        deleteAll.tap()
        let confirmAll = app.buttons["mail.senders.confirmDelete"].firstMatch
        XCTAssertTrue(confirmAll.waitForExistence(timeout: 5))
        confirmAll.tap()
        XCTAssertTrue(element(app, "mail.senders.report").label.contains("2"))
        XCTAssertTrue(waitForCount(rows, 5), "Ушедшие отправители должны пропасть из списка: \(rows.count)")

        // Рассылки ушли и из категории на экране почты, спам не тронут.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["mail.category.junk"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mail.category.junk"].label.contains("3"), app.buttons["mail.category.junk"].label)
        XCTAssertFalse(app.buttons["mail.category.newsletters"].exists, "Рассылки должны пропасть из категорий")

        // Сортировка по месту: сверху отправитель тяжёлого письма. Поиск по адресу оставляет одного.
        scrollTo(card, in: app)
        card.tap()
        XCTAssertTrue(waitForCount(rows, 5))
        pickSort(app, menu: "mail.senders.sort", "Больше места")
        let heaviest = NSPredicate(format: "label CONTAINS 'Тест Тяжёлое'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: heaviest, object: rows.element(boundBy: 0))], timeout: 5), .completed,
                       "Сверху должен быть отправитель тяжёлого письма: \(rows.element(boundBy: 0).label)")
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 3) {
            // В новых iOS поиск бывает свёрнут в кнопку на панели.
            app.buttons.matching(NSPredicate(format: "label IN %@", ["Поиск", "Search"])).firstMatch.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Нет поиска")
        search.tap()
        search.typeText("boss")
        XCTAssertTrue(waitForCount(rows, 1), "Поиск должен оставить одного отправителя: \(rows.count)")
        assertRunning(app)
    }

    /// Gmail подключается паролем приложения рядом с уже подключённой iCloud: проверка и чистка идут по обоим
    /// ящикам, а отключение Gmail не трогает iCloud.
    func testGmailConnectsAlongsideICloud() throws {
        let app = launch(extra: ["-seedMail"])
        app.tabBars.buttons["Главная"].tap()
        let tile = app.buttons["home.mail"]
        scrollTo(tile, in: app)
        tile.tap()

        let junk = app.buttons["mail.category.junk"]
        XCTAssertTrue(junk.waitForExistence(timeout: 15), "Категории почты не появились")
        XCTAssertTrue(junk.label.contains("3"), "Пока только iCloud: 3 письма в спаме, а не \(junk.label)")

        // Окно Gmail: подсказка ведёт на страницу паролей приложений Google, пароль вставляется с пробелами.
        let add = app.buttons["mail.add.gmail"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Нет кнопки добавления Gmail")
        add.tap()
        XCTAssertTrue(element(app, "mail.createPasswordLink").exists, "Нет кнопки создания пароля приложения")
        let email = app.textFields["mail.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText("test@gmail.com")
        let password = app.secureTextFields["mail.password"]
        password.tap()
        password.typeText("abcd efgh ijkl mnop")
        XCTAssertTrue(app.buttons["mail.signIn"].isEnabled, "Кнопка подключения должна стать доступной")
        attachScreenshot(app, "gmail-connect")
        // Клавиша ввода подключает сразу: кнопку внизу формы закрывает клавиатура.
        password.typeText("\n")

        // После подключения проверка идёт заново по обоим ящикам: спам 3 + 2.
        let gmailCard = element(app, "mail.account.gmail")
        XCTAssertTrue(gmailCard.label.contains("test@gmail.com"), gmailCard.label)
        XCTAssertTrue(element(app, "mail.account.icloud").exists, "iCloud должна остаться подключённой")
        let both = NSPredicate(format: "label CONTAINS %@", "5")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: both, object: app.buttons["mail.category.junk"])], timeout: 15), .completed,
                       "В спаме должно быть 5 писем из двух ящиков: \(app.buttons["mail.category.junk"].label)")
        attachScreenshot(app, "gmail-both")

        // В списке видно, из какого ящика письмо.
        app.buttons["mail.category.junk"].tap()
        let gmailRows = app.buttons.matching(NSPredicate(format: "identifier == 'mail.message' AND label CONTAINS 'Gmail'"))
        XCTAssertTrue(waitForCount(gmailRows, 2, timeout: 5), "В спаме должно быть 2 письма из Gmail")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Одна кнопка чистит оба ящика: iCloud 3 + 2 + 2, Gmail 2 + 1 + 1.
        let clean = app.buttons["mail.clean"]
        XCTAssertTrue(clean.waitForExistence(timeout: 5))
        XCTAssertTrue(clean.label.contains("11"), "Кнопка должна считать 11 писем: \(clean.label)")
        clean.tap()
        let confirm = app.buttons["mail.confirmClean"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let report = element(app, "mail.report")
        XCTAssertTrue(report.waitForExistence(timeout: 15), "Отчёт о чистке не появился")
        XCTAssertTrue(report.label.contains("11"), "Удалиться должны 11 писем: \(report.label)")

        // Отключаем только Gmail: iCloud остаётся, а Gmail снова можно добавить.
        app.buttons["mail.menu"].tap()
        app.buttons["mail.disconnect.gmail"].tap()
        let confirmDisconnect = app.buttons["mail.confirmDisconnect"].firstMatch
        XCTAssertTrue(confirmDisconnect.waitForExistence(timeout: 5))
        confirmDisconnect.tap()
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["mail.account.gmail"], timeout: 5), "Gmail не отключилась")
        XCTAssertTrue(app.descendants(matching: .any)["mail.account.icloud"].exists, "iCloud отключилась вместе с Gmail")
        XCTAssertTrue(app.buttons["mail.add.gmail"].waitForExistence(timeout: 5), "Gmail нельзя добавить снова")
        assertRunning(app)
    }

    /// Умная чистка сначала проверяет почту обоих ящиков и чистит её вместе с точными копиями одной кнопкой.
    /// По умолчанию уходят спам, «Удалённые» и рассылки (iCloud 3 + 2 + 2, Gmail 2 + 1 + 1):
    /// тяжёлые и старые непрочитанные выключены.
    func testSmartCleanCleansMailAndCopies() throws {
        let app = launch(extra: ["-seedMail", "-seedGmail"])
        app.tabBars.buttons["Главная"].tap()
        XCTAssertTrue(element(app, "home.mailPeriod").exists, "На главной нет периода почты")
        element(app, "home.smartClean").tap()

        let scan = app.buttons["smart.scan"]
        (scan.waitForExistence(timeout: 5) ? scan : app.buttons["smart.rescan"]).tap()
        XCTAssertTrue(app.buttons["smart.rescan"].waitForExistence(timeout: 300), "Анализ не закончился")

        let junk = element(app, "smart.mail.junk")
        XCTAssertTrue(junk.label.contains("5"), "В спаме должно быть 5 писем из двух ящиков: \(junk.label)")
        XCTAssertTrue(element(app, "smart.mailDetails").label.contains("Gmail"), "Карточка почты должна называть оба ящика")
        XCTAssertTrue(element(app, "smart.mail.trash").exists)
        XCTAssertTrue(element(app, "smart.mail.newsletters").exists)

        let clean = app.buttons["smart.clean"]
        XCTAssertTrue(clean.waitForExistence(timeout: 10), "Нет общей кнопки чистки")
        XCTAssertTrue(clean.label.contains("11"), "Кнопка должна считать 11 писем: \(clean.label)")
        clean.tap()
        let confirm = app.buttons["smart.confirmClean"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        let report = element(app, "smart.mailReport")
        XCTAssertTrue(report.label.contains("Удалено писем: 11"), "Удалиться должны 11 писем: \(report.label)")
        XCTAssertFalse(app.descendants(matching: .any)["smart.mail.junk"].exists, "Спам должен уйти")
        XCTAssertFalse(app.buttons["smart.clean"].exists, "После чистки кнопке нечего чистить")

        // С главной умную чистку можно запустить заново: каждый запуск проверяет всё с нуля.
        app.navigationBars.buttons.firstMatch.tap()
        let rescan = element(app, "home.rescan")
        rescan.tap()
        // Кнопка уступает место прогрессу: анализ действительно начался, а не закончился мгновенно на старых данных.
        XCTAssertTrue(waitForDisappearance(app.buttons["home.rescan"], timeout: 10), "Повторный анализ не начался")
        XCTAssertTrue(app.buttons["home.rescan"].waitForExistence(timeout: 300), "Повторный анализ не закончился")
        assertRunning(app)
    }

    // MARK: - Похожие

    /// Кнопка «Применить мой выбор» появляется снизу только после изменения отметок, исчезает, когда всё
    /// вернули как было, и разбирает только изменённые группы. Удержание показывает фото, а долгое открывает целиком.
    func testGroupsApplyMySelection() throws {
        let app = launch()
        try requirePhotos(app)
        app.tabBars.buttons["Главная"].tap()
        element(app, "home.smartClean").tap()
        app.buttons["smart.scan"].tap()
        XCTAssertTrue(app.buttons["smart.rescan"].waitForExistence(timeout: 300), "Анализ не закончился")
        element(app, "smart.similar").tap()

        let firstGroup = app.buttons["groups.applyGroup"].firstMatch
        guard firstGroup.waitForExistence(timeout: 3) else {
            throw XCTSkip("Нет похожих фото: наполните медиатеку симулятора (scripts/seed-simulator.sh)")
        }
        let before = try XCTUnwrap(totals(firstGroup), firstGroup.label)
        let applySelection = app.buttons["groups.applySelection"].firstMatch
        XCTAssertFalse(applySelection.exists, "Кнопка появилась без изменений")

        let photos = app.buttons.matching(identifier: "groups.photo")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 5))
        let candidates = [photos.element(boundBy: 0), photos.element(boundBy: 1)]
        let target = try XCTUnwrap(candidates.first { $0.value as? String == "В корзину" }, "В первой группе нечего удалять")

        // Короткое удержание только показывает фото поверх экрана: отпустил — закрылось, отметка та же.
        let close = app.buttons["fullscreen.close"]
        let peek = app.descendants(matching: .any).matching(identifier: "fullscreen.peek").firstMatch
        target.press(forDuration: 0.6)
        XCTAssertFalse(close.waitForExistence(timeout: 1.5), "Короткое удержание открыло фото целиком")
        XCTAssertTrue(waitForDisappearance(peek), "Фото поверх экрана не закрылось")
        XCTAssertEqual(target.value as? String, "В корзину")

        // Если держать дольше, фото открывается целиком.
        target.press(forDuration: 1.8)
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Долгое удержание не открыло фото целиком")
        XCTAssertFalse(peek.exists, "Фото поверх экрана осталось под полноэкранным просмотром")
        close.tap()
        XCTAssertEqual(target.value as? String, "В корзину")
        XCTAssertFalse(applySelection.exists)

        // Отметка и её отмена: кнопка появляется и исчезает.
        target.tap()
        XCTAssertEqual(target.value as? String, "Останется")
        XCTAssertTrue(applySelection.waitForExistence(timeout: 5), "Кнопка не появилась после изменения")
        let changed = NSPredicate(format: "label CONTAINS %@", "Оставить \(before.keep + 1), удалить \(before.trash - 1)")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: changed, object: applySelection)], timeout: 5), .completed, applySelection.label)
        target.tap()
        XCTAssertTrue(waitForDisappearance(applySelection), "Кнопка не исчезла после отмены")

        // Снова оставляем кадр и применяем: в корзину уходит только изменённая группа и без этого кадра.
        target.tap()
        XCTAssertTrue(applySelection.waitForExistence(timeout: 5))
        applySelection.tap()
        XCTAssertTrue(waitForDisappearance(applySelection), "Кнопка осталась после применения")

        app.tabBars.buttons["Корзина"].tap()
        let expected = before.trash - 1
        let trash = expected == 0
            ? app.staticTexts["Корзина пуста"]
            : app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "\(expected) объект")).firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 10), "Ожидалось \(expected) фото в корзине")
        assertRunning(app)
    }

    // MARK: - Статистика и настройки

    func testStatsSettingsAndReset() throws {
        let app = launch()
        try openSource(app, "all")
        let total = app.staticTexts["deck.position"].label
        app.buttons["deck.trash"].tap()
        waitForPosition(app, 2)
        app.buttons["deck.keep"].tap()
        waitForPosition(app, 3)

        app.tabBars.buttons["Статистика"].tap()
        XCTAssertTrue(app.staticTexts["Разобрано"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Настройки"].tap()
        let swap = app.switches["Поменять влево и вправо"]
        XCTAssertTrue(swap.waitForExistence(timeout: 5))
        swap.tap()
        swap.tap()
        let clearCache = app.buttons["Очистить кэш умной чистки"]
        scrollTo(clearCache, in: app)
        clearCache.tap()

        let reset = app.buttons["settings.reset"]
        scrollTo(reset, in: app)
        reset.tap()
        // Кнопки в системном диалоге iOS 27 вложены друг в друга, поэтому берём первое совпадение.
        let confirm = (app.buttons["settings.confirmReset"].exists ? app.buttons["settings.confirmReset"] : app.buttons["Сбросить"]).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        // После сброса открытые экраны не должны падать на удалённых записях.
        app.tabBars.buttons["Статистика"].tap()
        XCTAssertTrue(app.staticTexts["Разобрано"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Корзина"].tap()
        XCTAssertTrue(app.staticTexts["Корзина пуста"].waitForExistence(timeout: 5))

        // Стопка, открытая до сброса, сама не меняется; заново открытая начинается с начала.
        app.tabBars.buttons["Разбор"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        try openSource(app, "all")
        XCTAssertEqual(app.staticTexts["deck.position"].label, total)
        assertRunning(app)
    }

    // MARK: - Серия и напоминание

    /// Серия на главной растёт после первой чистки за день, стопка хвалит за это,
    /// а напоминание включается с главной, реально ставится в системе и после чистки переносится на завтра.
    func testStreakGrowsAndReminderMovesToTomorrow() throws {
        addUIInterruptionMonitor(withDescription: "Уведомления") { alert in
            for label in Self.notificationLabels where alert.buttons[label].exists {
                alert.buttons[label].firstMatch.tap()
                return true
            }
            return false
        }
        let app = launch(extra: ["-seedStreak", "3"])
        try requirePhotos(app)

        // Три прошлых дня с чисткой, сегодня ещё не чистили: серия держится и просит не прерывать её.
        app.tabBars.buttons["Главная"].tap()
        let streak = element(app, "home.streak")
        scrollTo(streak, in: app)
        XCTAssertTrue(streak.label.contains("3 дня"), "Серия из трёх дней не видна: \(streak.label)")
        XCTAssertTrue(streak.label.contains("не прервать"), streak.label)

        // Напоминание включается прямо с главной. Системный запрос разрешения бывает только при первом прогоне.
        let remind = element(app, "home.reminder")
        scrollTo(remind, in: app)
        XCTAssertTrue(remind.label.contains("Напоминать каждый день"), remind.label)
        remind.tap()
        tapSystemButton(app, Self.notificationLabels, timeout: 5)
        XCTAssertTrue(waitForLabel(remind, containing: "Напоминание в"), "Напоминание не включилось: \(remind.label)")
        attachScreenshot(app, "Серия и напоминание на главной")

        // В настройках время и ближайшее напоминание из тех, что действительно стоят в системе.
        app.tabBars.buttons["Настройки"].tap()
        let toggle = app.switches["settings.reminder"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(element(app, "settings.reminderTime").exists)
        let next = element(app, "settings.nextReminder")
        scrollTo(next, in: app)
        XCTAssertTrue(next.label.hasPrefix("Ближайшее"), next.label)

        // Первая чистка за день: стопка хвалит, серия растёт до четырёх дней.
        try openSource(app, "all")
        app.buttons["deck.keep"].tap()
        let toast = element(app, "deck.streak")
        XCTAssertTrue(toast.label.contains("4 дня"), "Нет похвалы за серию: \(toast.label)")
        attachScreenshot(app, "Похвала за серию в стопке")
        app.navigationBars.buttons.firstMatch.tap()

        app.tabBars.buttons["Главная"].tap()
        scrollTo(streak, in: app)
        XCTAssertTrue(waitForLabel(streak, containing: "4 дня"), streak.label)
        XCTAssertTrue(streak.label.contains("Сегодня уже чистили"), streak.label)

        // Сегодня уже чистили, поэтому сегодняшнее напоминание снято и ближайшее — завтра.
        app.tabBars.buttons["Настройки"].tap()
        let moved = element(app, "settings.nextReminder")
        XCTAssertTrue(waitForLabel(moved, containing: "завтра"), "Напоминание не перенеслось на завтра: \(moved.label)")
        attachScreenshot(app, "Напоминание в настройках")

        // Выключение убирает выбор времени.
        toggle.tap()
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["settings.reminderTime"]), "Время не скрылось после выключения")
        assertRunning(app)
    }

    // MARK: - Первый запуск

    func testOnboardingRequestsAccess() throws {
        allowPhotosPrompt()
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments = baseArguments
        app.launch()

        for _ in 0..<4 {
            let next = app.buttons["Далее"]
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            next.tap()
        }
        let allow = app.buttons["Разрешить доступ"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        allow.tap()
        XCTAssertTrue(tapSystemButton(app, Self.fullAccessLabels), "Не появился системный запрос доступа к фото")
        XCTAssertTrue(app.tabBars.buttons["Разбор"].waitForExistence(timeout: 10), "После разрешения не открылось приложение")
        assertRunning(app)
    }

    // MARK: - Помощники

    private static let fullAccessLabels = [
        "Allow Full Access", "Allow Access to All Photos",
        "Разрешить полный доступ", "Разрешить доступ ко всем фото",
    ]

    private static let deleteLabels = ["Delete", "Удалить"]
    private static let notificationLabels = ["Allow", "Разрешить"]
    private static let contactsAccessLabels = ["Allow Full Access", "Разрешить полный доступ", "Continue", "Продолжить", "OK", "Разрешить"]
    private static let calendarAccessLabels = ["Allow Full Access", "Разрешить полный доступ", "OK", "Разрешить"]

    private func enterPIN(_ app: XCUIApplication, _ code: String) {
        for digit in code {
            let key = app.buttons["pin.\(digit)"]
            XCTAssertTrue(key.waitForExistence(timeout: 5), "Нет клавиши \(digit)")
            key.tap()
        }
    }

    private var baseArguments: [String] {
        ["-uiTesting", "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
    }

    /// Если запрос доступа к фото всплыл не там, где тест его ждёт, XCTest по умолчанию жмёт «Не разрешать»,
    /// и все следующие тесты начинают с отказа. Этот обработчик разрешает доступ; другие окна он не трогает.
    private func allowPhotosPrompt() {
        addUIInterruptionMonitor(withDescription: "Доступ к фото") { alert in
            let allow = alert.buttons["kTCCServicePhotos-allow-button"].firstMatch
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
    }

    private func launch(extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        allowPhotosPrompt()
        let app = XCUIApplication()
        app.launchArguments = baseArguments + ["-onboardingCompleted", "YES"] + extra
        app.launch()
        // Если доступ к фото сброшен, приложение начинает со страницы доступа.
        let allow = app.buttons["Разрешить доступ"]
        if allow.waitForExistence(timeout: 2) {
            allow.tap()
            tapSystemButton(app, Self.fullAccessLabels)
        }
        XCTAssertTrue(app.tabBars.buttons["Разбор"].waitForExistence(timeout: 10))
        return app
    }

    /// Открывает подборку и ждёт первую карточку; без фото в медиатеке сценарий пропускается.
    private func openSource(_ app: XCUIApplication, _ id: String) throws {
        app.tabBars.buttons["Разбор"].tap()
        let tile = app.buttons["source.\(id)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.tap()
        let position = app.staticTexts["deck.position"]
        if !position.waitForExistence(timeout: 60) {
            throw XCTSkip("В подборке \(id) нет фото: наполните медиатеку симулятора (scripts/seed-simulator.sh)")
        }
        let first = NSPredicate(format: "label BEGINSWITH '1 из'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: first, object: position)], timeout: 5), .completed)
    }

    private func requirePhotos(_ app: XCUIApplication) throws {
        try openSource(app, "all")
        app.navigationBars.buttons.firstMatch.tap()
    }

    /// Свайп по карточке с заметной скоростью, как пальцем.
    private func swipeCard(_ app: XCUIApplication, dx: CGFloat, dy: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        let end = start.withOffset(CGVector(dx: dx, dy: dy))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func waitForPosition(_ app: XCUIApplication, _ expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        let position = app.staticTexts["deck.position"]
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "\(expected) из")
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: position)], timeout: 5)
        XCTAssertEqual(result, .completed, "Ожидалась карточка \(expected), на экране «\(position.label)»", file: file, line: line)
    }

    /// Числа из подписи «Оставить N, удалить M».
    private func totals(_ button: XCUIElement) -> (keep: Int, trash: Int)? {
        guard let match = button.label.firstMatch(of: /Оставить (\d+), удалить (\d+)/),
              let keep = Int(match.1), let trash = Int(match.2) else { return nil }
        return (keep, trash)
    }

    /// Размер из значения клетки сетки: «12,3 МБ» → байты. Точность подписи, но для порядка её хватает.
    private func bytes(_ element: XCUIElement) -> Double? {
        guard let value = element.value as? String else { return nil }
        let text = value.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        guard let match = text.firstMatch(of: /(\d+(?:[.,]\d+)?) ?(байт\w*|КБ|МБ|ГБ|ТБ|bytes|KB|MB|GB|TB)/),
              let number = Double(match.1.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let scale: Double = switch match.2 {
        case "КБ", "KB": 1e3
        case "МБ", "MB": 1e6
        case "ГБ", "GB": 1e9
        case "ТБ", "TB": 1e12
        default: 1
        }
        return number * scale
    }

    /// Число из сводки «Live Photos: N».
    private func liveCount(_ app: XCUIApplication) -> Int? {
        guard let match = element(app, "live.summary").label.firstMatch(of: /Live Photos: (\d+)/) else { return nil }
        return Int(match.1)
    }

    /// Число фото с карточки памяти на главной, когда оно перестало меняться: главная пересчитывает его
    /// после каждого изменения медиатеки.
    private func stablePhotoCount(_ app: XCUIApplication) -> Int? {
        func read() -> Int? {
            let label = element(app, "home.storage").label.replacingOccurrences(of: "\u{00A0}", with: "")
            guard let match = label.firstMatch(of: /(\d+) фото/) else { return nil }
            return Int(match.1)
        }
        var last = read()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            let now = read()
            if now != nil, now == last { return now }
            last = now
        }
        return last
    }

    /// Размеры первых клеток идут по убыванию или по возрастанию. Сетка пересобирается после закрытия меню,
    /// поэтому порядок проверяется несколько секунд, пока не совпадёт.
    private func assertSizes(_ items: XCUIElementQuery, descending: Bool, file: StaticString = #filePath, line: UInt = #line) {
        var sizes: [Double] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let count = min(items.count, 6)
            sizes = (0..<count).compactMap { bytes(items.element(boundBy: $0)) }
            let ordered = descending ? sizes.sorted(by: >) : sizes.sorted(by: <)
            if sizes.count == count, count > 0, sizes == ordered { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        XCTFail("Размеры не по \(descending ? "убыванию" : "возрастанию"): \(sizes)", file: file, line: line)
    }

    /// Выбирает порядок в меню сортировки на панели навигации.
    private func pickSort(_ app: XCUIApplication, menu id: String, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        element(app, id).tap()
        let button = app.buttons[title].firstMatch
        let option = button.waitForExistence(timeout: 5) ? button : app.menuItems[title].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 3), "В меню сортировки нет «\(title)»", file: file, line: line)
        option.tap()
    }

    /// Любой элемент по идентификатору: ссылки в списках бывают кнопками или ячейками.
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Нет элемента \(id)")
        return element
    }

    /// Листает вниз, пока элемент не окажется на экране: Form и ленивые сетки создают строки ниже края только при прокрутке.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 6) {
        for _ in 0..<attempts where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
    }

    /// Ждёт, пока подпись элемента не будет содержать текст (без учёта регистра).
    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elements.contains(where: { $0.exists }) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }

    private func waitForCount(_ query: XCUIElementQuery, _ count: Int, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "count == %d", count)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: query)], timeout: timeout) == .completed
    }

    /// Нажимает кнопку системного окна (доступ к фото, подтверждение удаления).
    /// Такие окна показывает не приложение, а система, поэтому ищем и в SpringBoard, и в приложении.
    /// В iOS 27 кнопки такого окна вложены друг в друга с одинаковой подписью и сообщают isHittable == false,
    /// хотя нажимаются, поэтому берём первое совпадение и проверяем только существование.
    /// Нажатие, пока окно ещё выезжает, система пропускает: поэтому ждём секунду и проверяем, что окно закрылось.
    @discardableResult
    private func tapSystemButton(_ app: XCUIApplication, _ labels: [String], timeout: TimeInterval = 10) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for scope in [springboard.alerts, app.alerts, springboard.sheets, app.sheets] {
                for label in labels {
                    let button = scope.buttons[label].firstMatch
                    if button.exists {
                        RunLoop.current.run(until: Date().addingTimeInterval(1))
                        button.tap()
                        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: button)
                        if XCTWaiter().wait(for: [gone], timeout: 3) == .completed { return true }
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }

    /// Снимок экрана в отчёт прогона: по нему видно, как выглядит экран, без ручного запуска.
    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertRunning(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "Приложение упало или ушло в фон", file: file, line: line)
    }
}
