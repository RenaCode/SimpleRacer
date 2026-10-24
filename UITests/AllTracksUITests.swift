import XCTest

/// Pełny przegląd: wyścig na każdej z 40 tras (auta po kolei, każde w kilku krainach) i każde auto do mety.
/// Długie (ok. 40 min) — uruchamiać po zmianach w trasach, autach i modelach:
/// `xcodebuild test … -only-testing:SimpleRacerUITests/AllTracksUITests`.
final class AllTracksUITests: XCTestCase {
    private static let trackCount = 40

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mute", "-logFile", "-resetProfile"] + args
        app.launch()
        return app
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

    private func int(_ s: [String: String], _ k: String) -> Int { s[k].flatMap(Int.init) ?? 0 }

    /// Czeka na warunek; zwraca ostatni stan albo nil po czasie.
    private func wait(_ app: XCUIApplication, _ timeout: TimeInterval, _ ok: ([String: String]) -> Bool) -> [String: String]? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let s = state(app)
            if !s.isEmpty, ok(s) { return s }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Każda trasa się buduje, auto rusza i jedzie dalej po kilku sekundach (bez rozbicia sceny i awarii).
    func testEveryTrack() {
        continueAfterFailure = true
        for track in 1...Self.trackCount {
            let app = launch(["-autostartRace", "-track", "\(track)", "-carIndex", "\(track - 1)"])
            guard let s = wait(app, 60, { self.int($0, "speed") > 120 }) else {
                XCTFail("trasa \(track): auto nie ruszyło — \(state(app))")
                shot(app, "trasa-\(track)-blad")
                app.terminate()
                continue
            }
            XCTAssertEqual(int(s, "auto"), 1, "trasa \(track): auto-prowadzenie wyłączone (przeciek ustawień z innego testu?)")
            Thread.sleep(forTimeInterval: 4)
            let later = state(app)
            XCTAssertEqual(int(later, "failed"), 0, "trasa \(track): błąd budowy trasy")
            XCTAssertGreaterThan(int(later, "speed"), 60, "trasa \(track) (\(s["car"] ?? "?")): auto stoi po starcie")
            shot(app, "trasa-\(track)-\(s["car"] ?? "?")")
            app.terminate()
        }
    }

    /// Każde auto przejeżdża cały wyścig (auto-prowadzenie) i widzi ekran wyników.
    func testEveryCarFinishes() {
        continueAfterFailure = true
        let probe = launch(["-autostartRace", "-track", "1"])
        let cars = wait(probe, 60, { self.int($0, "cars") > 0 }).map { int($0, "cars") } ?? 0
        probe.terminate()
        XCTAssertGreaterThan(cars, 0, "brak aut w katalogu")
        for i in 0..<cars {
            // Trasy z różnych krain, po kolei.
            let track = (i * 4) % Self.trackCount + 1
            let app = launch(["-autostartRace", "-autoNitro", "-track", "\(track)", "-carIndex", "\(i)"])
            let started = wait(app, 60, { self.int($0, "speed") > 60 })
            let car = started?["car"] ?? "auto \(i)"
            XCTAssertEqual(started.map { int($0, "auto") }, 1, "\(car): auto-prowadzenie wyłączone")
            let finished = app.buttons["Jeszcze raz"].waitForExistence(timeout: 300)
            XCTAssertTrue(finished, "\(car) na trasie \(track): brak mety po 5 min — \(state(app))")
            shot(app, "meta-\(car)-trasa-\(track)")
            app.terminate()
        }
    }
}
