import XCTest
@testable import RaceCore

/// Błędne dane wejściowe (cars.json, punkty trasy) nie mogą przerwać programu ani dać NaN w fizyce.
final class DataValidationTests: XCTestCase {
    private func car(topSpeed: Double = 60, accel: Double = 8, handling: Double = 1.2, nitro: Double = 1) -> CarDef {
        var d = CarCatalog.builtIn[0]
        d.topSpeed = topSpeed
        d.accel = accel
        d.handling = handling
        d.nitroPower = nitro
        return d
    }

    func testCarWithZeroOrNaNStatsIsInvalid() {
        XCTAssertTrue(car().isValid)
        XCTAssertFalse(car(topSpeed: 0).isValid)
        XCTAssertFalse(car(topSpeed: .nan).isValid)
        XCTAssertFalse(car(accel: -1).isValid)
        XCTAssertFalse(car(handling: .infinity).isValid)
        XCTAssertFalse(car(nitro: -0.5).isValid)
        XCTAssertTrue(car(nitro: 0).isValid, "auto bez nitro jest dopuszczalne")
    }

    func testBuiltInCarsAreValid() {
        for d in CarCatalog.builtIn { XCTAssertTrue(d.isValid, d.id) }
    }

    func testReplaceAllSkipsInvalidCars() {
        let saved = CarCatalog.all
        defer { CarCatalog.replaceAll(with: saved) }
        var bad = car(topSpeed: 0)
        bad.id = "zepsute"
        var good = car()
        good.id = "dobre"
        CarCatalog.replaceAll(with: [bad, good])
        XCTAssertEqual(CarCatalog.all.map(\.id), ["dobre"])
        // Same błędne: katalog bez zmian (nie zostaje pusty).
        CarCatalog.replaceAll(with: [bad])
        XCTAssertEqual(CarCatalog.all.map(\.id), ["dobre"])
    }

    func testSampleAtNaNDoesNotCrash() {
        let t = TrackData.makeCityLoop()
        for s in [Double.nan, .infinity, -.infinity] {
            let p = t.sample(at: s)
            XCTAssertTrue(p.x.isFinite && p.z.isFinite && p.heading.isFinite, "\(s)")
        }
    }

    func testRepeatedControlPointsGiveFiniteTrack() {
        let square: [SIMD2<Double>] = [[0, 0], [200, 0], [200, 0], [200, 200], [0, 200], [0, 0]]
        let t = Track(points: square, halfWidth: 10)
        XCTAssertTrue(t.length.isFinite && t.length > 600, "długość \(t.length)")
        for s in stride(from: 0, to: t.length, by: 7) {
            let p = t.sample(at: s)
            XCTAssertTrue(p.x.isFinite && p.z.isFinite && p.curvature.isFinite, "s=\(s)")
        }
    }
}
