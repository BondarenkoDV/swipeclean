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

    // MARK: - Почта iCloud

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

        // Отключение убирает пароль из связки ключей и возвращает экран подключения.
        app.buttons["mail.menu"].tap()
        app.buttons["mail.disconnect"].tap()
        let confirmDisconnect = app.buttons["mail.confirmDisconnect"].firstMatch
        XCTAssertTrue(confirmDisconnect.waitForExistence(timeout: 5))
        confirmDisconnect.tap()
        XCTAssertTrue(app.buttons["mail.connect"].waitForExistence(timeout: 5), "После отключения нет кнопки подключения")
        XCTAssertTrue(element(app, "mail.createPassword").exists, "Нет кнопки создания пароля приложения")
        assertRunning(app)
    }

    /// Умная чистка сначала проверяет почту и чистит её вместе с точными копиями одной кнопкой.
    /// По умолчанию уходят спам (3), «Удалённые» (2) и рассылки (2): тяжёлые и старые непрочитанные выключены.
    func testSmartCleanCleansMailAndCopies() throws {
        let app = launch(extra: ["-seedMail"])
        app.tabBars.buttons["Главная"].tap()
        XCTAssertTrue(element(app, "home.mailPeriod").exists, "На главной нет периода почты")
        element(app, "home.smartClean").tap()

        let scan = app.buttons["smart.scan"]
        (scan.waitForExistence(timeout: 5) ? scan : app.buttons["smart.rescan"]).tap()
        XCTAssertTrue(app.buttons["smart.rescan"].waitForExistence(timeout: 300), "Анализ не закончился")

        let junk = element(app, "smart.mail.junk")
        XCTAssertTrue(junk.label.contains("3"), "В спаме должно быть 3 письма: \(junk.label)")
        XCTAssertTrue(element(app, "smart.mail.trash").exists)
        XCTAssertTrue(element(app, "smart.mail.newsletters").exists)

        let clean = app.buttons["smart.clean"]
        XCTAssertTrue(clean.waitForExistence(timeout: 10), "Нет общей кнопки чистки")
        XCTAssertTrue(clean.label.contains("7"), "Кнопка должна считать 7 писем: \(clean.label)")
        clean.tap()
        let confirm = app.buttons["smart.confirmClean"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        let report = element(app, "smart.mailReport")
        XCTAssertTrue(report.label.contains("Удалено писем: 7"), "Удалиться должны 7 писем: \(report.label)")
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
