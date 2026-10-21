import XCTest

/// Garaż dotykiem: każde auto po kolei i kilka kolorów lakieru na każdym (zrzuty w wynikach testu do obejrzenia
/// — czy model się wczytał i lakier zmienia kolor). Aplikacja ma przeżyć całą serię i dalej odpowiadać.
final class GarageColorsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testEveryCarEveryColor() {
        let app = XCUIApplication()
        app.launchArguments = ["-mute", "-screen", "garage"]
        app.launch()
        XCTAssertTrue(app.buttons["Gotowe"].waitForExistence(timeout: 60), "garaż się nie pokazał")
        // Kafelki aut: nazwa i „moc N” (w pełnej wersji wszystkie auta są kupione).
        let tiles = app.buttons.matching(NSPredicate(format: "label CONTAINS 'moc '"))
        // Menu odsłania się dla dostępności po wygaszeniu splasha; kafelki siatki (LazyVGrid) dochodzą do drzewa
        // chwilę po przycisku „Gotowe” — liczenie od razu dawało 0.
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10), "brak kafelków aut")
        let count = tiles.count
        XCTAssertGreaterThanOrEqual(count, 2, "za mało aut w garażu")
        // Modele wczytują się w tle — chwila na wczytanie wszystkich przed serią.
        Thread.sleep(forTimeInterval: 12)
        for i in 0..<count {
            let tile = tiles.element(boundBy: i)
            let name = tile.label.components(separatedBy: " moc ").first ?? "auto \(i)"
            tile.tap()
            Thread.sleep(forTimeInterval: 2)
            for hex in ["#3A86FF", "#FFD60A", "#1B1B1E"] {
                let swatch = app.buttons["Kolor \(hex)"]
                XCTAssertTrue(swatch.waitForExistence(timeout: 5), "brak koloru \(hex)")
                swatch.tap()
                Thread.sleep(forTimeInterval: 1.5)
                shot(app, "\(i + 1) \(name) \(hex)")
            }
            XCTAssertEqual(app.state, .runningForeground, "aplikacja padła przy \(name)")
        }
        XCTAssertTrue(app.buttons["Gotowe"].exists, "garaż przestał odpowiadać")
    }
}
