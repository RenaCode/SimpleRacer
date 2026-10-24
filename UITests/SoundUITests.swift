import XCTest

/// Dźwięk bez słuchania: gra z `-audioProbe` pokazuje w niewidocznej etykiecie `test.audio` poziom sygnału
/// na wyjściu miksera (dBFS z ostatnich ~0,5 s, cisza = -200), przełączniki i liczniki efektów.
/// Test BEZ `-mute` — w symulatorze gra przez głośniki Maca. Muzyka (głośność 0,45) daje ok. -30 dBFS,
/// więc progi są szerokie: „gra” > -50, „cisza” < -90.
final class SoundUITests: XCTestCase {
    private static let loud = -50
    private static let silent = -90

    private func probe(_ app: XCUIApplication) -> [String: String] {
        let e = app.staticTexts["test.audio"]
        guard e.exists else { return [:] }
        var out: [String: String] = [:]
        for pair in e.label.split(separator: " ") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }

    private func rms(_ s: [String: String]) -> Int { Int(s["rms"] ?? "") ?? -999 }

    /// Liczba odtworzeń efektu od startu aplikacji (`fx=beep:3,go:1`).
    private func fx(_ s: [String: String], _ name: String) -> Int {
        for item in (s["fx"] ?? "").split(separator: ",") {
            let kv = item.split(separator: ":")
            if kv.count == 2, kv[0] == name { return Int(kv[1]) ?? 0 }
        }
        return 0
    }

    @discardableResult
    private func expect(_ app: XCUIApplication, _ what: String, timeout: TimeInterval = 15,
                        _ ok: ([String: String]) -> Bool) -> [String: String] {
        let end = Date().addingTimeInterval(timeout)
        var last: [String: String] = [:]
        while Date() < end {
            last = probe(app)
            if !last.isEmpty, ok(last) { return last }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("\(what) — sonda: \(app.staticTexts["test.audio"].exists ? app.staticTexts["test.audio"].label : "brak")")
        return last
    }

    private func player(_ app: XCUIApplication) -> [String: String] {
        let e = app.staticTexts["test.player"]
        guard e.exists else { return [:] }
        var out: [String: String] = [:]
        for pair in e.label.split(separator: " ") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }

    private func raceRunning(_ app: XCUIApplication) -> Bool {
        let end = Date().addingTimeInterval(90)
        while Date() < end {
            if Int(player(app)["speed"] ?? "") ?? 0 > 60 { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Ustawienia z menu: przełącznik `name` na `on`, zamknięcie arkusza.
    private func setting(_ name: String, _ on: Bool, in app: XCUIApplication) {
        let open = app.buttons["Ustawienia"]
        XCTAssertTrue(open.waitForExistence(timeout: 15), "brak przycisku Ustawienia")
        open.tap()
        let toggle = app.switches[name]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "brak przełącznika \(name)")
        for _ in 0..<3 where (toggle.value as? String == "1") != on {
            // Wiersz Form nie przełącza się po stuknięciu w środek — trzeba trafić w sam przełącznik w środku.
            let knob = toggle.switches.firstMatch
            (knob.exists ? knob : toggle).tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(toggle.value as? String == "1", on, "\(name): przełącznik nie zmienił stanu")
        app.buttons["Zamknij"].tap()
        XCTAssertTrue(app.buttons["Ścigaj się"].waitForExistence(timeout: 10), "Ustawienia się nie zamknęły")
    }

    /// Pauza → Menu.
    private func leaveRace(_ app: XCUIApplication) {
        app.buttons["Pauza"].tap()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 10), "brak menu pauzy")
        app.buttons["Menu"].tap()
        XCTAssertTrue(app.buttons["Ścigaj się"].waitForExistence(timeout: 20), "nie wraca do menu")
    }

    func testSoundEverywhere() {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-audioProbe", "-logFile", "-resetProfile"]
        app.launch()
        XCTAssertTrue(app.buttons["Ścigaj się"].waitForExistence(timeout: 90), "menu się nie pokazało")

        // 1. Menu: gra muzyka z menu.
        expect(app, "menu: brak muzyki", timeout: 20) {
            $0["running"] == "1" && $0["track"] == "menu" && $0["music"] == "1" && rms($0) > Self.loud
        }

        // 2. Wyścig: muzyka wyścigu, odliczanie (beep ×3, go) i silnik.
        app.buttons["Ścigaj się"].tap()
        XCTAssertTrue(raceRunning(app), "wyścig nie ruszył")
        let race = expect(app, "wyścig: brak dźwięku") {
            ($0["track"] ?? "").hasPrefix("race") && rms($0) > Self.loud
        }
        XCTAssertGreaterThanOrEqual(fx(race, "beep"), 3, "brak odliczania: \(race["fx"] ?? "")")
        XCTAssertGreaterThanOrEqual(fx(race, "go"), 1, "brak sygnału startu: \(race["fx"] ?? "")")

        // 3. Pauza: silnik cichnie, muzyka gra dalej; po „Graj dalej” znów dźwięk.
        app.buttons["Pauza"].tap()
        XCTAssertTrue(app.buttons["Graj dalej"].waitForExistence(timeout: 10), "brak menu pauzy")
        expect(app, "pauza: muzyka ucichła") { rms($0) > Self.loud }
        app.buttons["Graj dalej"].tap()
        expect(app, "po pauzie: brak dźwięku") { rms($0) > Self.loud }

        // 4. „Wycisz” w wyścigu: cisza; „Włącz dźwięk”: wraca.
        app.buttons["Wycisz"].tap()
        expect(app, "wyciszenie w wyścigu: nie ma ciszy") { $0["music"] == "0" && $0["sound"] == "0" && rms($0) < Self.silent }
        app.buttons["Włącz dźwięk"].tap()
        expect(app, "po włączeniu dźwięku w wyścigu: cisza") { $0["music"] == "1" && $0["sound"] == "1" && rms($0) > Self.loud }
        leaveRace(app)
        expect(app, "menu po wyścigu: brak muzyki menu") { $0["track"] == "menu" && rms($0) > Self.loud }

        // 5. Dźwięki wyłączone w Ustawieniach: wyścig gra samą muzykę, bez efektów odliczania.
        setting("Dźwięki", false, in: app)
        let before = expect(app, "Dźwięki wyłączone, a sonda tego nie widzi") { $0["sound"] == "0" && $0["music"] == "1" }
        app.buttons["Ścigaj się"].tap()
        XCTAssertTrue(raceRunning(app), "wyścig bez dźwięków nie ruszył")
        let quiet = expect(app, "wyścig bez dźwięków: brak muzyki") { ($0["track"] ?? "").hasPrefix("race") && rms($0) > Self.loud }
        XCTAssertEqual(fx(quiet, "beep"), fx(before, "beep"), "odliczanie gra mimo wyłączonych dźwięków")
        XCTAssertEqual(fx(quiet, "go"), fx(before, "go"), "sygnał startu gra mimo wyłączonych dźwięków")
        leaveRace(app)

        // 6. Muzyka też wyłączona: cisza w menu. Muzyka z powrotem: gra.
        setting("Muzyka", false, in: app)
        expect(app, "muzyka i dźwięki wyłączone: nie ma ciszy") { $0["music"] == "0" && rms($0) < Self.silent }
        setting("Muzyka", true, in: app)
        expect(app, "muzyka włączona z powrotem: cisza") { $0["music"] == "1" && rms($0) > Self.loud }

        // 7. Powrót z tła: muzyka wraca.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        expect(app, "po powrocie z tła: cisza", timeout: 20) { $0["running"] == "1" && rms($0) > Self.loud }

        // 8. Ponowne uruchomienie: ustawienia zapamiętane (muzyka tak, dźwięki nie), potem dźwięki z powrotem.
        app.terminate()
        app.launchArguments = ["-audioProbe", "-logFile"]
        app.launch()
        XCTAssertTrue(app.buttons["Ścigaj się"].waitForExistence(timeout: 90), "menu po ponownym uruchomieniu")
        expect(app, "po ponownym uruchomieniu: ustawienia dźwięku niezapamiętane", timeout: 20) {
            $0["running"] == "1" && $0["music"] == "1" && $0["sound"] == "0" && rms($0) > Self.loud
        }
        setting("Dźwięki", true, in: app)
        expect(app, "Dźwięki włączone z powrotem") { $0["sound"] == "1" }
    }
}
