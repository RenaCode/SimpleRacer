import XCTest

/// Ekran ładowania wyścigu: auto wybrane, zanim się wczytało, błąd wczytania, wyjście w tło w trakcie ładowania.
final class LoadingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mute", "-logFile"] + args
        app.launch()
        return app
    }

    private func speed(_ app: XCUIApplication) -> Int {
        // Etykieta HUD powstaje dopiero z wyścigiem; odczyt nieistniejącej przerywa test.
        let hud = app.staticTexts["test.player"]
        guard hud.exists else { return 0 }
        let label = hud.label
        let pair = label.split(separator: " ").first { $0.hasPrefix("speed=") }
        return pair.flatMap { Int($0.dropFirst("speed=".count)) } ?? 0
    }

    /// Garaż → n-te auto → menu → „Ścigaj się”. Testy startują z `-carIndex 0`: auto wybrane w poprzednim
    /// teście zostaje w profilu i wczytywałoby się jako pierwsze, czyli już nie „zanim się wczytało”.
    private func pickCarAndRace(_ app: XCUIApplication, index: Int) {
        XCTAssertTrue(app.buttons["Gotowe"].waitForExistence(timeout: 60), "garaż się nie pokazał")
        let tiles = app.buttons.matching(NSPredicate(format: "label CONTAINS 'moc '"))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10), "brak kafelków aut")
        XCTAssertGreaterThan(tiles.count, index, "za mało aut w garażu")
        // Inne auta zdążą się wczytać — przy 6 wczytanych wyścig wstrzymuje dalsze wczytywanie.
        Thread.sleep(forTimeInterval: 5)
        tiles.element(boundBy: index).tap()
        app.buttons["Gotowe"].tap()
        let race = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ścigaj się'")).firstMatch
        XCTAssertTrue(race.waitForExistence(timeout: 5), "brak „Ścigaj się”")
        race.tap()
    }

    /// Auto wybrane w garażu, zanim się wczytało (tu: wczytuje się dopiero, gdy wyścig czeka i 6 innych aut jest gotowych). Wcześniej ekran ładowania
    /// czekał na nie bez końca: blokada wczytywania w czasie wyścigu obejmowała też auto gracza.
    func testRaceWithCarPickedBeforeItLoaded() {
        let app = launch(["-screen", "garage", "-carIndex", "0", "-slowCar", "8"])
        pickCarAndRace(app, index: 8)
        let end = Date().addingTimeInterval(100)
        while Date() < end, speed(app) < 120 { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertGreaterThanOrEqual(speed(app), 120, "wyścig nie ruszył — ekran ładowania wisi")
    }

    /// Auto gracza się nie wczytuje: komunikat zamiast zastępczego modelu, „Menu” wraca do menu.
    func testFailedCarShowsErrorAndMenuWorks() {
        let app = launch(["-screen", "garage", "-carIndex", "0", "-failCar", "8"])
        pickCarAndRace(app, index: 8)
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Nie udało się wczytać auta'")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 30), "brak komunikatu o błędzie wczytania")
        XCTAssertTrue(app.buttons["Spróbuj ponownie"].exists)
        app.buttons["Menu"].tap()
        XCTAssertTrue(app.buttons["Garaż"].waitForExistence(timeout: 10), "„Menu” nie wróciło do menu")
    }

    /// Wyjście z aplikacji w trakcie ładowania: po powrocie i odsłonięciu sceny gra stoi w pauzie.
    func testBackgroundDuringLoadingPausesRace() {
        let app = launch(["-autostartRace", "-track", "1"])
        Thread.sleep(forTimeInterval: 1)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(app.buttons["Graj dalej"].waitForExistence(timeout: 60), "po powrocie z tła brak pauzy")
    }
}
