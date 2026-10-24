import XCTest

/// Cała kampania od zera, jak u dziecka: trasy 1–40 po kolei, każdy wyścig do mety (auto-prowadzenie), monety
/// z wyścigów na ulepszenia, gdy trasa mówi „Za słabe auto”. Brak monet na potrzebne ulepszenie to błąd balansu.
/// Krótko (`TEST_RUNNER_CAMPAIGN_FAST=1`, meta od razu — ok. 20 min) albo w całości (ok. 1,5 h).
final class CampaignUITests: XCTestCase {
    private static let env = ProcessInfo.processInfo.environment
    private static let fast = env["CAMPAIGN_FAST"] == "1"
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
        for id in 1...Self.lastTrack {
            guard app.state == .runningForeground else { XCTFail("trasa \(id): aplikacja nie działa"); return }
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
                let n = buyUpgrades(app)
                upgrades += n
                print("trasa \(id): kupiono \(n) ulepszeń")
                app.buttons["Gotowe"].tap()
                guard tap("Kampania", until: Self.regions[0], in: app), openTrack(id, app) else {
                    XCTFail("trasa \(id): powrót do kampanii"); return
                }
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
