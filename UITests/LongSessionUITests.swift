import XCTest

/// Długa sesja jak u dziecka, BEZ zamykania aplikacji: menu → garaż (auto i kolor) → kampania → wyścig →
/// pauza → menu, w kółko. Każde auto na każdej z 40 tras, lakier z palety po kolei (każde auto jeździ we
/// wszystkich kolorach). Wykrywa przecieki (pamięć w Documents/perf.log rośnie z wyścigu na wyścig),
/// zawieszenia nawigacji i nagrzewanie (stan termiczny w tym samym logu). Bardzo długie (2–3 h):
/// `xcodebuild test … -only-testing:SimpleRacerUITests/LongSessionUITests`.
final class LongSessionUITests: XCTestCase {
    /// Zakres do próby na krótko: `TEST_RUNNER_LONG_TRACKS=2 TEST_RUNNER_LONG_CARS=2 xcodebuild test …`.
    private static let env = ProcessInfo.processInfo.environment
    private static let trackCount = Int(env["LONG_TRACKS"] ?? "") ?? 40
    private static let carLimit = Int(env["LONG_CARS"] ?? "") ?? .max
    /// Start od wybranej trasy (odtworzenie błędu z dalszej części sesji): `TEST_RUNNER_LONG_FIRST_TRACK=32`.
    private static let firstTrack = Int(env["LONG_FIRST_TRACK"] ?? "") ?? 1
    /// `TEST_RUNNER_LONG_ALL_COLORS=1`: pełny iloczyn auto × kolor × trasa (~3000 wyścigów, ~17 h) zamiast
    /// kolorów po kolei (każda para auto–trasa, auto–kolor i trasa–kolor, ~440 wyścigów).
    private static let allColors = env["LONG_ALL_COLORS"] == "1"
    private static let colors = ["#E63946", "#F77F00", "#FFD60A", "#2A9D8F", "#3A86FF", "#8338EC", "#F1F1F1", "#1B1B1E"]
    private static let regions = ["Miasto", "Wybrzeże", "Pustynia", "Las", "Śnieg"]

    private func state(_ app: XCUIApplication) -> [String: String] {
        let probe = app.staticTexts["test.player"]
        guard probe.exists else { return [:] }
        var out: [String: String] = [:]
        for pair in probe.label.split(separator: " ") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }

    private func int(_ s: [String: String], _ k: String) -> Int { s[k].flatMap(Int.init) ?? 0 }

    private func wait(_ app: XCUIApplication, _ timeout: TimeInterval, _ ok: ([String: String]) -> Bool) -> [String: String]? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let s = state(app)
            if !s.isEmpty, ok(s) { return s }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    /// Stuka w `button`, aż pojawi się `next` (pierwsze stuknięcie bywa pochłonięte przez wygaszany splash).
    private func tap(_ button: String, until next: String, in app: XCUIApplication, tries: Int = 3) -> Bool {
        for _ in 0..<tries {
            guard app.buttons[button].waitForExistence(timeout: 30) else { return false }
            app.buttons[button].tap()
            if app.buttons[next].waitForExistence(timeout: 8) { return true }
        }
        return false
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Garaż: auto o numerze `car` i kolor `hex` (auta z bajki nie mają palety — wtedy tylko auto).
    /// Auto-prowadzenie w menu musi być włączone (długa sesja na iPadzie: raz wyłączyło się bez śladu i auto
    /// rozbijało się o bandy). Zgłasza błąd, włącza z powrotem i jedzie dalej.
    private func ensureAutoSteer(in app: XCUIApplication, race: Int) {
        let pill = app.buttons["Auto-prowadzenie"]
        guard pill.waitForExistence(timeout: 10) else { return }
        if (pill.value as? String) == "OFF" {
            XCTFail("wyścig \(race): auto-prowadzenie w menu wyłączone — włączam z powrotem")
            shot(app, "auto-prowadzenie-off-\(race)")
            pill.tap()
        }
    }

    /// Zwraca nazwę auta i to, czy auto ma paletę, albo nil, gdy garaż nie odpowiada.
    private func pick(car: Int, hex: String, in app: XCUIApplication) -> (name: String, palette: Bool)? {
        guard tap("Garaż", until: "Gotowe", in: app) else { return nil }
        let tiles = app.buttons.matching(NSPredicate(format: "label CONTAINS 'moc '"))
        guard tiles.firstMatch.waitForExistence(timeout: 10), car < tiles.count else { return nil }
        let tile = tiles.element(boundBy: car)
        let name = tile.label.components(separatedBy: " moc ").first ?? "auto \(car)"
        tile.tap()
        let swatch = app.buttons["Kolor \(hex)"]
        let palette = swatch.waitForExistence(timeout: 2)
        if palette { swatch.tap() }
        app.buttons["Gotowe"].tap()
        return (name, palette)
    }

    /// Kampania: kraina trasy i karta trasy.
    private func start(track id: Int, in app: XCUIApplication) -> Bool {
        guard app.buttons["Kampania"].waitForExistence(timeout: 15) else { return false }
        app.buttons["Kampania"].tap()
        let region = app.buttons[Self.regions[(id - 1) / 8]]
        guard region.waitForExistence(timeout: 10) else { return false }
        region.tap()
        // Etykieta karty zaczyna się numerem trasy („12, …”); `MATCHES` — żeby „1” nie trafiało w „10”.
        let card = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "\(id)(\\D.*)?")).firstMatch
        guard card.waitForExistence(timeout: 10) else { return false }
        card.tap()
        return true
    }

    /// Pauza → Menu (wyjście z wyścigu bez zamykania aplikacji).
    private func backToMenu(_ app: XCUIApplication) -> Bool {
        let pause = app.buttons["Pauza"]
        guard pause.waitForExistence(timeout: 10) else { return false }
        pause.tap()
        let menu = app.buttons["Menu"]
        guard menu.waitForExistence(timeout: 10) else { return false }
        menu.tap()
        return app.buttons["Garaż"].waitForExistence(timeout: 20)
    }

    func testEveryCarEveryTrackOneSession() {
        continueAfterFailure = true
        let app = XCUIApplication()
        // `TEST_RUNNER_LONG_ARGS="-noPostFX -noMSAA"` — dodatkowe argumenty (pomiar A/B w warunkach sesji).
        app.launchArguments = ["-mute", "-logFile", "-allUpgrades"] + (Self.env["LONG_ARGS"].map { $0.split(separator: " ").map(String.init) } ?? [])
        app.launch()
        XCTAssertTrue(app.buttons["Garaż"].waitForExistence(timeout: 90), "menu się nie pokazało")
        XCTAssertTrue(tap("Garaż", until: "Gotowe", in: app), "garaż się nie otwiera")
        let tiles = app.buttons.matching(NSPredicate(format: "label CONTAINS 'moc '"))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 15), "brak kafelków aut")
        let cars = min(tiles.count, Self.carLimit)
        app.buttons["Gotowe"].tap()
        XCTAssertGreaterThan(cars, 0, "brak aut w garażu")
        // Modele wczytują się w tle — chwila, żeby pierwsze wyścigi nie czekały na całą listę.
        Thread.sleep(forTimeInterval: 15)

        var race = 0
        for track in Self.firstTrack...Self.trackCount {
            for car in 0..<cars {
              for k in 0..<(Self.allColors ? Self.colors.count : 1) {
                race += 1
                let hex = Self.colors[Self.allColors ? k : (car + track) % Self.colors.count]
                guard app.state == .runningForeground else {
                    XCTFail("wyścig \(race): aplikacja nie działa (\(app.state.rawValue)) — koniec sesji")
                    return
                }
                ensureAutoSteer(in: app, race: race)
                guard let (name, palette) = pick(car: car, hex: hex, in: app) else {
                    XCTFail("wyścig \(race), trasa \(track), auto \(car): garaż nie odpowiada")
                    shot(app, "garaz-blad-\(race)")
                    return
                }
                guard start(track: track, in: app) else {
                    XCTFail("wyścig \(race), trasa \(track), \(name): nie da się wejść na trasę")
                    shot(app, "kampania-blad-\(race)")
                    return
                }
                guard let s = wait(app, 60, { self.int($0, "speed") > 120 }) else {
                    XCTFail("trasa \(track), \(name): auto nie ruszyło — \(state(app))")
                    shot(app, "start-blad-\(race)")
                    if !backToMenu(app) { return }
                    continue
                }
                XCTAssertEqual(int(s, "auto"), 1, "trasa \(track), \(name): auto-prowadzenie wyłączone")
                // ~6 s jazdy: jedno podsumowanie klatek w logu (co 300 klatek).
                Thread.sleep(forTimeInterval: 6)
                let later = state(app)
                XCTAssertEqual(int(later, "failed"), 0, "trasa \(track), \(name): błąd budowy trasy")
                XCTAssertGreaterThan(int(later, "speed"), 60, "trasa \(track), \(name): auto stoi")
                if car == 0 { shot(app, "trasa-\(track)-\(name)-\(hex)") }
                guard backToMenu(app) else {
                    XCTFail("wyścig \(race), trasa \(track), \(name): nie wraca do menu")
                    shot(app, "menu-blad-\(race)")
                    return
                }
                // Auto bez palety (malowanie w teksturze): pozostałe kolory nic by nie zmieniły.
                if !palette { break }
              }
            }
        }
        XCTAssertEqual(app.state, .runningForeground, "aplikacja padła pod koniec sesji")
    }
}
