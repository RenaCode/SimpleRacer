import XCTest

/// Testy rozgrywki w symulatorze: dotyka przycisków tak jak dziecko na iPadzie i sprawdza stan gracza
/// z niewidocznej etykiety HUD `test.player` (liczniki driftów, nitro i skrętu — tylko Debug/Family).
final class GameplayUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        // -mute: symulator gra przez głośniki Maca.
        app.launchArguments = ["-mute"] + args
        app.launch()
        return app
    }

    /// Liczniki z etykiety `test.player`, np. "drifts=1 nitros=0 left=0 right=0 speed=180 paused=0".
    private func state(_ app: XCUIApplication) -> [String: Int] {
        let label = app.staticTexts["test.player"].label
        var out: [String: Int] = [:]
        for pair in label.split(separator: " ") {
            let kv = pair.split(separator: "=")
            if kv.count == 2, let v = Int(kv[1]) { out[String(kv[0])] = v }
        }
        return out
    }

    /// Czeka, aż warunek na stanie gracza będzie spełniony (wyścig ładuje się kilka–kilkanaście sekund).
    private func wait(_ app: XCUIApplication, timeout: TimeInterval, _ what: String,
                      _ ok: ([String: Int]) -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if app.staticTexts["test.player"].exists, ok(state(app)) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("\(what) — stan: \(app.staticTexts["test.player"].exists ? app.staticTexts["test.player"].label : "brak HUD")")
    }

    private func raceStarted(_ app: XCUIApplication) {
        wait(app, timeout: 60, "auto się nie rozpędziło") { ($0["speed"] ?? 0) > 120 }
    }

    /// Przytrzymany DRIFT wprowadza auto w poślizg — z auto-prowadzeniem i bez skrętu.
    func testDriftButtonStartsDrift() {
        let app = launch(["-autostartRace", "-track", "1"])
        raceStarted(app)
        let before = state(app)["drifts"] ?? 0
        app.buttons["Drift"].press(forDuration: 2.5)
        wait(app, timeout: 3, "DRIFT nie wprowadził auta w poślizg") { ($0["drifts"] ?? 0) > before }
    }

    /// Bez auto-prowadzenia DRIFT też wprowadza auto w poślizg.
    func testDriftWithManualSteering() {
        let app = launch(["-manualSteer", "-autostartRace", "-track", "1"])
        raceStarted(app)
        let before = state(app)["drifts"] ?? 0
        app.buttons["Drift"].press(forDuration: 2)
        wait(app, timeout: 3, "DRIFT bez auto-prowadzenia nie wprowadził auta w poślizg") { ($0["drifts"] ?? 0) > before }
    }

    /// Krótkie dotknięcie DRIFT też daje drift (pół sekundy poślizgu).
    func testShortDriftTap() {
        let app = launch(["-autostartRace", "-track", "1"])
        raceStarted(app)
        let before = state(app)["drifts"] ?? 0
        app.buttons["Drift"].tap()
        wait(app, timeout: 3, "krótkie dotknięcie DRIFT nie dało driftu") { ($0["drifts"] ?? 0) > before }
    }

    /// Drift ładuje nitro, a dotknięcie NITRO je odpala.
    func testNitroAfterDrift() {
        let app = launch(["-autostartRace", "-track", "1"])
        raceStarted(app)
        app.buttons["Drift"].press(forDuration: 4)
        let before = state(app)["nitros"] ?? 0
        app.buttons["Nitro"].tap()
        wait(app, timeout: 3, "NITRO nie odpaliło") { ($0["nitros"] ?? 0) > before }
    }

    /// ◀ i ▶ docierają do sterowania (z auto-prowadzeniem zmieniają pas).
    func testSteeringButtons() {
        let app = launch(["-autostartRace", "-track", "1"])
        raceStarted(app)
        app.buttons["W lewo"].press(forDuration: 0.8)
        wait(app, timeout: 2, "◀ nie skręca") { ($0["left"] ?? 0) > 0 }
        app.buttons["W prawo"].press(forDuration: 0.8)
        wait(app, timeout: 2, "▶ nie skręca") { ($0["right"] ?? 0) > 0 }
    }

    /// Pauza zatrzymuje wyścig, „Graj dalej” go wznawia.
    func testPauseAndResume() {
        let app = launch(["-autostartRace", "-track", "1"])
        raceStarted(app)
        app.buttons["Pauza"].tap()
        XCTAssertTrue(app.buttons["Graj dalej"].waitForExistence(timeout: 3))
        wait(app, timeout: 2, "pauza nie zatrzymała gry") { $0["paused"] == 1 }
        app.buttons["Graj dalej"].tap()
        wait(app, timeout: 3, "gra nie wróciła po pauzie") { $0["paused"] == 0 }
    }

    /// Menu → garaż (wszystkie auta bez kłódek w pełnej wersji) → menu → kampania → wyścig z kampanii.
    func testMenuGarageCampaignRace() {
        let app = launch([])
        XCTAssertTrue(app.buttons["Garaż"].waitForExistence(timeout: 60), "menu się nie pokazało")
        app.buttons["Garaż"].tap()
        XCTAssertTrue(app.buttons["Gotowe"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Kup za'")).firstMatch.exists,
                       "w pełnej wersji żadne auto nie jest na sprzedaż")
        app.buttons["Gotowe"].tap()
        XCTAssertTrue(app.buttons["Kampania"].waitForExistence(timeout: 5))
        app.buttons["Kampania"].tap()
        // Ostatnia trasa pierwszej krainy jest otwarta od razu (pełna wersja).
        let track8 = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '8'")).firstMatch
        XCTAssertTrue(track8.waitForExistence(timeout: 5), "brak karty trasy 8")
        track8.tap()
        raceStarted(app)
    }
}
