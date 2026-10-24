import XCTest

/// Cała kampania od zera, jak u dziecka: trasy 1–40 po kolei, każdy wyścig do mety (auto-prowadzenie), monety
/// z wyścigów na ulepszenia, gdy trasa mówi „Za słabe auto”. Brak monet na potrzebne ulepszenie to błąd balansu.
/// Krótko (`TEST_RUNNER_CAMPAIGN_FAST=1`, meta od razu — ok. 20 min) albo w całości (ok. 1,5 h).
/// `TEST_RUNNER_CAMPAIGN_MIX=1`: przed każdą trasą garaż (kolejne posiadane auto, kolejny kolor), w trakcie
/// wyścigu pauza i „Graj dalej” — jak dziecko, które przegląda auta między wyścigami. Pamięć: Documents/perf.log.
final class CampaignUITests: XCTestCase {
    private static let env = ProcessInfo.processInfo.environment
    private static let fast = env["CAMPAIGN_FAST"] == "1"
    private static let mix = env["CAMPAIGN_MIX"] == "1"
    private static let colors = ["#E63946", "#F77F00", "#FFD60A", "#2A9D8F", "#3A86FF", "#8338EC", "#F1F1F1", "#1B1B1E"]
    /// Próba na krótko: `TEST_RUNNER_CAMPAIGN_LAST=3`.
    private static let lastTrack = Int(env["CAMPAIGN_LAST"] ?? "") ?? 40
    private static let regions = ["Miasto", "Wybrzeże", "Pustynia", "Las", "Śnieg"]

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Stuka w `button`, aż pojawi się `next` (pierwsze stuknięcie bywa pochłonięte przez wygaszany splash).
    private func tap(_ button: String, until next: String, in app: XCUIApplication) -> Bool {
        for _ in 0..<3 {
            guard app.buttons[button].waitForExistence(timeout: 30) else { return false }
            app.buttons[button].tap()
            if app.buttons[next].waitForExistence(timeout: 8) { return true }
        }
        return false
    }

    /// Garaż: kupuje najtańsze dostępne ulepszenia auta gracza, aż skończą się monety. Zwraca liczbę zakupów.
    private func buyUpgrades(_ app: XCUIApplication) -> Int {
        var bought = 0
        for _ in 0..<40 {
            let buttons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ulepsz.'")).allElementsBoundByIndex
            let enabled = buttons.filter { $0.isEnabled }
            // Najtańsze pierwsze: etykieta przycisku to koszt.
            guard let cheapest = enabled.min(by: { (Int($0.label.filter(\.isNumber)) ?? .max) < (Int($1.label.filter(\.isNumber)) ?? .max) })
            else { break }
            cheapest.tap()
            bought += 1
            Thread.sleep(forTimeInterval: 0.3)
        }
        return bought
    }

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

    private func wait(_ app: XCUIApplication, _ timeout: TimeInterval, _ ok: ([String: String]) -> Bool) -> [String: String]? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let s = state(app)
            if !s.isEmpty, ok(s) { return s }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    /// Posiadane auta w garażu (kafelek z „moc N”; zablokowane mają kłódkę i cenę).
    private func ownedTiles(_ app: XCUIApplication) -> [XCUIElement] {
        let tiles = app.buttons.matching(NSPredicate(format: "label CONTAINS 'moc '"))
        guard tiles.firstMatch.waitForExistence(timeout: 10) else { return [] }
        return tiles.allElementsBoundByIndex
    }

    private func power(_ tile: XCUIElement) -> Int {
        Int(tile.label.components(separatedBy: "moc ").last?.filter(\.isNumber) ?? "") ?? 0
    }

    /// Garaż otwarty: wybiera auto `tile` i kolor `hex` (auta bez palety — samo auto). Zwraca nazwę auta.
    private func choose(_ tile: XCUIElement, hex: String, in app: XCUIApplication) -> String {
        let name = tile.label.components(separatedBy: " moc ").first ?? tile.label
        tile.tap()
        let swatch = app.buttons["Kolor \(hex)"]
        if swatch.waitForExistence(timeout: 2) { swatch.tap() }
        return name
    }

    /// Menu → garaż: kolejne posiadane auto i kolor, z powrotem do menu. Zwraca nazwę auta albo nil.
    private func garageMix(race id: Int, in app: XCUIApplication) -> String? {
        guard tap("Garaż", until: "Gotowe", in: app) else { return nil }
        let owned = ownedTiles(app)
        guard !owned.isEmpty else { return nil }
        let name = choose(owned[id % owned.count], hex: Self.colors[id % Self.colors.count], in: app)
        app.buttons["Gotowe"].tap()
        return app.buttons["Kampania"].waitForExistence(timeout: 15) ? name : nil
    }

    /// W trakcie wyścigu: pauza (gra stoi), „Graj dalej” (gra jedzie). Meta przed pauzą (krótki tryb) — pomija.
    private func pauseAndResume(race id: Int, in app: XCUIApplication) {
        guard wait(app, 60, { Int($0["speed"] ?? "") ?? 0 > 60 }) != nil else { return }
        let pause = app.buttons["Pauza"]
        guard pause.exists, pause.isHittable else { return }
        pause.tap()
        guard app.buttons["Graj dalej"].waitForExistence(timeout: 10) else {
            if !app.buttons["Jeszcze raz"].exists { XCTFail("trasa \(id): brak menu pauzy"); shot(app, "kampania-\(id)-pauza") }
            return
        }
        XCTAssertNotNil(wait(app, 5, { $0["paused"] == "1" }), "trasa \(id): pauza nie zatrzymała gry")
        let lap = state(app)["lap"]
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(state(app)["lap"], lap, "trasa \(id): okrążenie zmieniło się w pauzie")
        app.buttons["Graj dalej"].tap()
        XCTAssertNotNil(wait(app, 10, { $0["paused"] == "0" && Int($0["speed"] ?? "") ?? 0 > 30 }),
                        "trasa \(id): po „Graj dalej” gra nie ruszyła — \(state(app))")
    }

    private func openTrack(_ id: Int, _ app: XCUIApplication) -> Bool {
        let region = app.buttons[Self.regions[(id - 1) / 8]]
        guard region.waitForExistence(timeout: 15) else { return false }
        region.tap()
        let card = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "\(id)(\\D.*)?")).firstMatch
        guard card.waitForExistence(timeout: 10) else { return false }
        card.tap()
        return true
    }

    func testWholeCampaign() {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-mute", "-logFile", "-resetProfile"] + (Self.fast ? ["-finishSoon"] : [])
            + (Self.env["CAMPAIGN_ARGS"].map { $0.split(separator: " ").map(String.init) } ?? [])
        app.launch()
        XCTAssertTrue(app.buttons["Kampania"].waitForExistence(timeout: 90), "menu się nie pokazało")
        XCTAssertTrue(tap("Kampania", until: Self.regions[0], in: app), "kampania się nie otwiera")

        var upgrades = 0
        var lastCar = ""
        for id in 1...Self.lastTrack {
            guard app.state == .runningForeground else { XCTFail("trasa \(id): aplikacja nie działa"); return }
            var carName = ""
            if Self.mix {
                // Z mapy kampanii przez „Menu” do garażu i z powrotem do kampanii.
                guard tap("Menu", until: "Garaż", in: app), let name = garageMix(race: id, in: app),
                      tap("Kampania", until: Self.regions[0], in: app) else {
                    XCTFail("trasa \(id): garaż przed wyścigiem"); shot(app, "kampania-\(id)-garaz"); return
                }
                carName = name
            }
            guard openTrack(id, app) else {
                XCTFail("trasa \(id): brak karty trasy"); shot(app, "kampania-\(id)-brak"); return
            }
            // Za słabe auto → garaż, ulepszenia za zarobione monety, z powrotem na trasę.
            var tries = 0
            while app.alerts["Za słabe auto"].waitForExistence(timeout: 2) {
                tries += 1
                guard tries <= 3 else {
                    XCTFail("trasa \(id): auto wciąż za słabe po ulepszeniach — brak monet (balans kampanii)")
                    shot(app, "kampania-\(id)-za-slabe"); return
                }
                app.alerts["Za słabe auto"].buttons["Do garażu"].tap()
                guard app.buttons["Gotowe"].waitForExistence(timeout: 15) else { XCTFail("trasa \(id): garaż"); return }
                // Wymieszane auta: wraca do najmocniejszego (na nie idą monety), inaczej ulepszenia rozchodzą się po wszystkich.
                if Self.mix, let best = ownedTiles(app).max(by: { power($0) < power($1) }) {
                    carName = choose(best, hex: Self.colors[id % Self.colors.count], in: app)
                }
                let n = buyUpgrades(app)
                upgrades += n
                print("trasa \(id): kupiono \(n) ulepszeń")
                app.buttons["Gotowe"].tap()
                guard tap("Kampania", until: Self.regions[0], in: app), openTrack(id, app) else {
                    XCTFail("trasa \(id): powrót do kampanii"); return
                }
            }
            if Self.mix {
                if let s = wait(app, 60, { !($0["car"] ?? "").isEmpty }) {
                    if id > 1, s["car"] == lastCar, carName != "" { print("trasa \(id): to samo auto co poprzednio (\(carName))") }
                    lastCar = s["car"] ?? ""
                }
                pauseAndResume(race: id, in: app)
            }
            // Meta: ekran wyników.
            let results = app.buttons["Jeszcze raz"]
            guard results.waitForExistence(timeout: Self.fast ? 90 : 360) else {
                XCTFail("trasa \(id): brak mety"); shot(app, "kampania-\(id)-bez-mety")
                return
            }
            if id % 8 == 0 { shot(app, "kampania-\(id)-wynik") }
            guard tap("Kampania", until: Self.regions[0], in: app) else { XCTFail("trasa \(id): wyniki → kampania"); return }
        }
        print("kampania ukończona, ulepszeń: \(upgrades)")
        shot(app, "kampania-koniec")
    }
}
