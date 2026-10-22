import Foundation
import XCTest
@testable import RaceCore

/// Zapis kampanii musi przetrwać zmiany w kodzie: brak pola, nieznane ulepszenie albo nowy klucz
/// nie mogą kończyć się błędem dekodowania (aplikacja zaczyna wtedy nową grę i nadpisuje postęp).
final class SaveFormatTests: XCTestCase {
    private func decode(_ json: String) throws -> CampaignState {
        try JSONDecoder().decode(CampaignState.self, from: Data(json.utf8))
    }

    /// Zapis z samymi monetami: reszta pól domyślna, zamiast `keyNotFound`.
    func testMissingFieldsGetDefaults() throws {
        let st = try decode(#"{"coins":5}"#)
        XCTAssertEqual(st.coins, 5)
        XCTAssertEqual(st.bestStars, [:])
        XCTAssertEqual(st.ownedCars, [])
        XCTAssertEqual(st.upgrades, [:])
    }

    /// Zapis w dzisiejszym formacie (ulepszenia jako naprzemienna tablica nazwa, poziom) czyta się bez strat.
    func testCurrentFormatRoundTrip() throws {
        var st = Campaign.newGame()
        st.coins = 1234
        st.bestStars = [1: 3, 2: 2, 17: 1]
        st.ownedCars = ["strzala", "grom"]
        st.upgrades = ["strzala": [.engine: 2, .nitro: 1], "grom": [.handling: 5]]
        let back = try JSONDecoder().decode(CampaignState.self, from: JSONEncoder().encode(st))
        XCTAssertEqual(back, st)
        // Zapis sprzed wersjonowania, dosłownie tak, jak go zapisywała aplikacja.
        let old = try decode(#"{"bestStars":{"3":2},"coins":3,"ownedCars":["strzala"],"upgrades":{"strzala":["engine",2,"nitro",1]}}"#)
        XCTAssertEqual(old.coins, 3)
        XCTAssertEqual(old.bestStars, [3: 2])
        XCTAssertEqual(old.ownedCars, ["strzala"])
        XCTAssertEqual(old.upgrades, ["strzala": [.engine: 2, .nitro: 1]])
    }

    /// Zapis niesie wersję formatu, a ulepszenia zostają w dotychczasowym kształcie (zgodność wstecz).
    func testEncodedFormatHasVersionAndOldUpgradeShape() throws {
        var st = CampaignState(coins: 3, ownedCars: ["strzala"])
        st.bestStars = [3: 2]
        st.upgrades = ["strzala": [.engine: 2]]
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let json = String(decoding: try enc.encode(st), as: UTF8.self)
        XCTAssertEqual(json, #"{"bestStars":{"3":2},"coins":3,"ownedCars":["strzala"],"upgrades":{"strzala":["engine",2]},"version":1}"#)
    }

    /// Ulepszenie, którego ta wersja nie zna (np. dodane w nowszej), jest pomijane — reszta zostaje.
    func testUnknownUpgradeIsSkipped() throws {
        let st = try decode(#"{"coins":7,"upgrades":{"strzala":["engine",2,"turbo",3,"nitro",1],"grom":["turbo",1]}}"#)
        XCTAssertEqual(st.coins, 7)
        XCTAssertEqual(st.upgrades["strzala"], [.engine: 2, .nitro: 1])
        XCTAssertEqual(st.upgrades["grom"] ?? [:], [:])
    }

    /// Nieznany klucz najwyższego poziomu jest ignorowany.
    func testUnknownTopLevelKeyIsIgnored() throws {
        let st = try decode(##"{"coins":9,"ownedCars":["strzala"],"garageColor":"#FF0000"}"##)
        XCTAssertEqual(st.coins, 9)
        XCTAssertEqual(st.ownedCars, ["strzala"])
    }
}
