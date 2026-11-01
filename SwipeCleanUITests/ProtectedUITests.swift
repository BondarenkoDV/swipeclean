import XCTest

/// Список «Не трогать»: защищённое фото уходит из разбора, корзины и умной чистки, а список можно пополнять и чистить.
/// Медиатеку симулятора нужно заранее наполнить (`scripts/seed-simulator.sh`). Список в UI-тестах живёт в памяти,
/// поэтому каждый запуск начинается с пустого, а сами фото тесты не удаляют.
@MainActor
final class ProtectedUITests: XCTestCase {
    /// Защита из полноэкранного просмотра: карточка сразу уходит из стопки и не возвращается при новом открытии
    /// подборки, фото появляется в списке, а снятая защита возвращает его в разбор.
    func testProtectFromFullScreenLeavesDeckAndShowsInList() throws {
        let app = launch()
        try openSource(app, "all")
        let total = try XCTUnwrap(deckTotal(app), app.staticTexts["deck.position"].label)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        let protect = app.buttons["fullscreen.protect"]
        XCTAssertTrue(protect.waitForExistence(timeout: 5), "В полноэкранном просмотре нет кнопки «Не трогать»")
        XCTAssertEqual(protect.value as? String, "Не защищено")
        protect.tap()
        XCTAssertTrue(waitForValue(protect, "Защищено"), "Кнопка не переключилась: \(String(describing: protect.value))")
        app.buttons["fullscreen.close"].tap()
        XCTAssertTrue(waitForTotal(app, total - 1), "Защищённая карточка осталась в стопке: \(app.staticTexts["deck.position"].label)")

        // Подборка открывается заново без защищённого фото.
        app.navigationBars.buttons.firstMatch.tap()
        try openSource(app, "all")
        XCTAssertTrue(waitForTotal(app, total - 1), "Защищённое фото снова в разборе: \(app.staticTexts["deck.position"].label)")
        app.navigationBars.buttons.firstMatch.tap()

        openProtectedList(app)
        let items = app.buttons.matching(identifier: "protected.item")
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10), "Фото не появилось в списке «Не трогать»")
        XCTAssertEqual(items.count, 1)

        // Снимаем защиту через режим выбора: список пустеет, фото возвращается в разбор.
        element(app, "protected.select").tap()
        items.firstMatch.tap()
        element(app, "protected.remove").tap()
        XCTAssertTrue(app.staticTexts["Список пуст"].waitForExistence(timeout: 5), "Список не опустел после снятия защиты")
        app.navigationBars.buttons.firstMatch.tap()
        try openSource(app, "all")
        XCTAssertTrue(waitForTotal(app, total), "После снятия защиты фото не вернулось в разбор")
        assertRunning(app)
    }

    /// Фото из корзины после защиты возвращается как оставленное; в список можно добавить фото из медиатеки.
    func testProtectedPhotoLeavesTrashAndPickerAddsMore() throws {
        let app = launch()
        try openSource(app, "all")
        app.buttons["deck.trash"].tap()
        let position = app.staticTexts["deck.position"]
        XCTAssertTrue(waitFor(position, NSPredicate(format: "label BEGINSWITH '2 из'")), position.label)

        app.tabBars.buttons["Корзина"].tap()
        let trashItems = app.buttons.matching(identifier: "trash.item")
        XCTAssertTrue(trashItems.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(trashItems.count, 1)
        trashItems.firstMatch.tap()
        let protect = app.buttons["fullscreen.protect"]
        XCTAssertTrue(protect.waitForExistence(timeout: 5))
        protect.tap()
        XCTAssertTrue(waitForValue(protect, "Защищено"))
        app.buttons["fullscreen.close"].tap()
        XCTAssertTrue(app.staticTexts["Корзина пуста"].waitForExistence(timeout: 10), "Защищённое фото осталось в корзине")

        openProtectedList(app)
        let items = app.buttons.matching(identifier: "protected.item")
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(items.count, 1)

        // Добавляем ещё два фото через выбор из медиатеки: уже защищённое там не показывается.
        element(app, "protected.add").tap()
        let picker = app.buttons.matching(identifier: "protectedPicker.item")
        XCTAssertTrue(picker.firstMatch.waitForExistence(timeout: 30), "Выбор фото не открылся")
        picker.element(boundBy: 0).tap()
        picker.element(boundBy: 1).tap()
        element(app, "protectedPicker.add").tap()
        XCTAssertTrue(waitForCount(items, 3), "Ожидалось 3 фото в списке, на экране \(items.count)")
        XCTAssertTrue(element(app, "protected.count").label.contains("3"), element(app, "protected.count").label)

        // Защиту избранного можно выключить.
        let toggle = element(app, "protected.favorites")
        XCTAssertEqual(toggle.value as? String, "1", "Защита избранного должна быть включена по умолчанию")
        // Нажатие по подписи переключатель SwiftUI не меняет: жмём по самому переключателю у правого края.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(waitForValue(toggle, "0"), "Переключатель избранного не выключился")
        assertRunning(app)
    }

    /// Умная чистка: защищённая копия остаётся, отметить её к удалению нельзя, и новая проверка её тоже не предлагает.
    func testSmartCleanKeepsProtectedDuplicate() throws {
        let app = launch()
        try requirePhotos(app)
        app.tabBars.buttons["Главная"].tap()
        element(app, "home.smartClean").tap()
        app.buttons["smart.scan"].tap()
        XCTAssertTrue(app.buttons["smart.rescan"].waitForExistence(timeout: 300), "Анализ не закончился")
        element(app, "smart.duplicates").tap()

        let photos = app.buttons.matching(identifier: "groups.photo")
        guard photos.firstMatch.waitForExistence(timeout: 5) else {
            throw XCTSkip("Нет дубликатов: наполните медиатеку симулятора (scripts/seed-simulator.sh)")
        }
        let copies = app.buttons.matching(NSPredicate(format: "identifier == 'groups.photo' AND value == 'В корзину'"))
        let copy = copies.firstMatch
        XCTAssertTrue(copy.exists, "В первой группе нечего удалять")

        // Долгое удержание открывает копию целиком, там её и защищаем.
        copy.press(forDuration: 1.8)
        let protect = app.buttons["fullscreen.protect"]
        XCTAssertTrue(protect.waitForExistence(timeout: 5), "Долгое удержание не открыло фото целиком")
        protect.tap()
        XCTAssertTrue(waitForValue(protect, "Защищено"))
        app.buttons["fullscreen.close"].tap()

        let protectedPhotos = app.buttons.matching(NSPredicate(format: "identifier == 'groups.photo' AND value == 'Не трогать'"))
        let kept = protectedPhotos.firstMatch
        XCTAssertTrue(kept.waitForExistence(timeout: 5), "Защищённая копия не помечена щитом")
        kept.tap()
        XCTAssertEqual(kept.value as? String, "Не трогать", "Защищённую копию удалось отметить к удалению")
        XCTAssertFalse(app.buttons["groups.applySelection"].exists, "Защита посчитана как изменение отметок")

        // Новая проверка с нуля тоже оставляет защищённую копию.
        app.navigationBars.buttons.firstMatch.tap()
        let rescan = app.buttons["smart.rescan"]
        rescan.tap()
        // Кнопка пропадает на время анализа; на маленькой медиатеке он может закончиться раньше проверки.
        _ = waitFor(rescan, NSPredicate(format: "exists == false"), timeout: 10)
        XCTAssertTrue(rescan.waitForExistence(timeout: 300), "Повторный анализ не закончился")
        element(app, "smart.duplicates").tap()
        XCTAssertTrue(protectedPhotos.firstMatch.waitForExistence(timeout: 10), "После новой проверки защищённая копия снова предложена к удалению")
        assertRunning(app)
    }

    // MARK: - Помощники

    private static let fullAccessLabels = [
        "Allow Full Access", "Allow Access to All Photos",
        "Разрешить полный доступ", "Разрешить доступ ко всем фото",
    ]

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Доступ к фото") { alert in
            let allow = alert.buttons["kTCCServicePhotos-allow-button"].firstMatch
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-onboardingCompleted", "YES"]
        app.launch()
        let allow = app.buttons["Разрешить доступ"]
        if allow.waitForExistence(timeout: 2) {
            allow.tap()
            tapSystemButton(app, Self.fullAccessLabels)
        }
        XCTAssertTrue(app.tabBars.buttons["Разбор"].waitForExistence(timeout: 10))
        return app
    }

    private func openSource(_ app: XCUIApplication, _ id: String) throws {
        app.tabBars.buttons["Разбор"].tap()
        let tile = app.buttons["source.\(id)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.tap()
        let position = app.staticTexts["deck.position"]
        if !position.waitForExistence(timeout: 60) {
            throw XCTSkip("В подборке \(id) нет фото: наполните медиатеку симулятора (scripts/seed-simulator.sh)")
        }
        XCTAssertTrue(waitFor(position, NSPredicate(format: "label BEGINSWITH '1 из'")), position.label)
    }

    private func requirePhotos(_ app: XCUIApplication) throws {
        try openSource(app, "all")
        app.navigationBars.buttons.firstMatch.tap()
    }

    private func openProtectedList(_ app: XCUIApplication) {
        app.tabBars.buttons["Главная"].tap()
        // Плитка внизу ленивой сетки: её нет в дереве, пока до неё не долистали.
        let tile = app.buttons["home.protected"]
        for _ in 0..<6 where !(tile.exists && tile.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "На главной нет плитки «Не трогать»")
        tile.tap()
        XCTAssertTrue(element(app, "protected.count").exists)
    }

    /// Сколько карточек в стопке: «1 из 57» → 57.
    private func deckTotal(_ app: XCUIApplication) -> Int? {
        let label = app.staticTexts["deck.position"].label
        guard let match = label.firstMatch(of: /из (\d+)/) else { return nil }
        return Int(match.1)
    }

    private func waitForTotal(_ app: XCUIApplication, _ total: Int) -> Bool {
        waitFor(app.staticTexts["deck.position"], NSPredicate(format: "label ENDSWITH %@", "из \(total)"))
    }

    private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
        waitFor(element, NSPredicate(format: "value == %@", value))
    }

    private func waitFor(_ object: Any, _ predicate: NSPredicate, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: object)], timeout: timeout) == .completed
    }

    private func waitForCount(_ query: XCUIElementQuery, _ count: Int, timeout: TimeInterval = 10) -> Bool {
        waitFor(query, NSPredicate(format: "count == %d", count), timeout: timeout)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Нет элемента \(id)")
        return element
    }

    /// Кнопка системного окна: в iOS 27 такие кнопки вложены друг в друга и сообщают isHittable == false.
    @discardableResult
    private func tapSystemButton(_ app: XCUIApplication, _ labels: [String], timeout: TimeInterval = 10) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for scope in [springboard.alerts, app.alerts] {
                for label in labels {
                    let button = scope.buttons[label].firstMatch
                    if button.exists {
                        RunLoop.current.run(until: Date().addingTimeInterval(1))
                        button.tap()
                        return true
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }

    private func assertRunning(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "Приложение упало или ушло в фон", file: file, line: line)
    }
}
