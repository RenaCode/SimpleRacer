import XCTest
@testable import RaceCore

/// Przypadki brzegowe fizyki znalezione fuzzingiem (160 pełnych wyścigów: każda trasa × 4 sposoby jazdy).
final class PhysicsEdgeTests: XCTestCase {
    private final class Hold: Controller {
        func read(car: Car, dt: Double, ctx: RaceContext) -> CarInput { CarInput() }
    }

    private func sim(laps: Int) -> RaceSim {
        RaceSim(track: TrackData.makeCityLoop(), entries: [
            Entry(name: "R", def: CarCatalog.builtIn[0], color: "#FFFFFF", isPlayer: false, controller: Hold()),
            Entry(name: "P", def: CarCatalog.builtIn[0], color: "#FFFFFF", isPlayer: true, controller: Hold()),
        ], laps: laps)
    }

    /// Rywal pół okrążenia dalej, który dogania gracza: znak `wrapDelta` przeskakuje z −len/2 na +len/2,
    /// co wyglądało jak wyprzedzenie — „NA WŁOS!” i nitro za auto oddalone o setki metrów.
    func testNoNearMissFromRivalHalfALapAway() {
        let sim = sim(laps: 2)
        let track = sim.track
        let r = sim.cars[0], p = sim.cars[1]
        p.distance = 10; p.s = 10; p.d = 2.7; p.speed = 10
        r.distance = 10 + track.length / 2 - 0.5; r.s = wrap(r.distance, track.length); r.d = 0; r.speed = 30
        var nearMisses = 0
        for _ in 0..<20 {
            sim.advance()
            nearMisses += sim.events.filter { if case .nearMiss = $0 { return true }; return false }.count
            sim.events.removeAll()
        }
        XCTAssertEqual(nearMisses, 0)
    }

    /// Dwa auta za metą w tym samym kroku fizyki: wyżej to, które przejechało dalej, a nie to,
    /// które stoi wcześniej na liście (gracz jest zawsze ostatni na liście).
    func testSameStepFinishGoesToCarFurtherOverTheLine() {
        let sim = sim(laps: 1)
        let len = sim.track.length
        let r = sim.cars[0], p = sim.cars[1]
        r.distance = len - 0.30; r.s = wrap(r.distance, len); r.speed = 40; r.d = 4
        p.distance = len - 0.01; p.s = wrap(p.distance, len); p.speed = 40; p.d = -4
        sim.advance()
        XCTAssertEqual(sim.finishOrder.map(\.name), ["P", "R"])
        XCTAssertEqual(sim.position(of: p), 1)
    }

    /// Takedown i rozbicie ofiary w tej samej porcji zdarzeń (wcześniej rozbicie przychodziło krok później).
    func testTakedownAndWreckInSameStep() {
        let sim = sim(laps: 2)
        let r = sim.cars[0], p = sim.cars[1]
        r.distance = 100; r.s = 100; r.d = 0; r.speed = 20
        p.distance = 96; p.s = 96; p.d = 0; p.speed = 50
        sim.advance()
        XCTAssertTrue(r.wrecked)
        XCTAssertTrue(sim.events.contains { if case .takedown = $0 { return true }; return false })
        XCTAssertTrue(sim.events.contains { if case .wreck(let c) = $0 { return c === r }; return false })
    }

    /// Odepchnięcie od tyłu przy prędkości < 1 m/s nie może dać prędkości ujemnej (auto toczyło się wstecz).
    func testRearPushNeverMakesSpeedNegative() {
        let len = 1000.0, def = CarCatalog.builtIn[0]
        let front = Car(name: "F", def: def, color: "#FFFFFF", isPlayer: false, startDistance: 104, startLane: 0, trackLength: len)
        let back = Car(name: "B", def: def, color: "#FFFFFF", isPlayer: false, startDistance: 100, startLane: 0, trackLength: len)
        front.speed = 0; back.speed = 0.5
        _ = Collisions.resolve([front, back], trackLength: len)
        XCTAssertGreaterThanOrEqual(back.speed, 0)
    }

    /// Po odepchnięciu bokiem (ścisk trzech aut) auto nie zostaje w bandzie do następnego kroku.
    func testCollisionPushStaysInsideWalls() {
        let sim = sim(laps: 2)
        let limit = sim.track.halfWidth - Physics.carWidth / 2
        let r = sim.cars[0], p = sim.cars[1]
        r.distance = 200; r.s = 200; r.d = limit; r.speed = 30
        p.distance = 200; p.s = 200; p.d = limit - Physics.carWidth * 0.5; p.speed = 30
        sim.advance()
        for car in sim.cars { XCTAssertLessThanOrEqual(abs(car.d), limit + 1e-9, car.name) }
    }

    /// Włącza falę uderzeniową (dwa szybkie wciśnięcia NITRO przy pełnym pasku).
    private func shockwave(_ car: Car) {
        car.nitro.gauge = 1
        car.nitro.update(dt: 0.01, pressed: true)
        car.nitro.update(dt: 0.01, pressed: true)
        XCTAssertEqual(car.nitro.mode, .shockwave)
    }

    /// Fala uderzeniowa rozbija rywala przy każdym styku — także gdy to rywal ociera się bokiem mocniej
    /// (wcześniej „napastnikiem” zostawał ten, kto mocniej pcha, i gracz kończył jako ofiara, której nic się nie dzieje).
    func testPlayerShockwaveWrecksRivalRubbingHarder() {
        let len = 2000.0
        let def = CarCatalog.builtIn[0]
        let p = Car(name: "P", def: def, color: "#FFFFFF", isPlayer: true, startDistance: 100, startLane: 0, trackLength: len)
        let r = Car(name: "R", def: def, color: "#FFFFFF", isPlayer: false, startDistance: 100, startLane: 0, trackLength: len)
        p.speed = 40; r.speed = 40
        p.d = 0; r.d = def.shape.width - 0.2 // r po lewej, styk bokiem
        p.alphaVel = 0; r.alphaVel = -0.1 // rywal zjeżdża na gracza, gracz jedzie prosto
        shockwave(p)
        let out = Collisions.resolve([p, r], trackLength: len)
        XCTAssertTrue(r.wrecked)
        XCTAssertFalse(p.wrecked)
        XCTAssertEqual(out.map(\.victim.name), ["R"])
    }

    /// To samo przy najechaniu od tyłu: rywal, który wjeżdża w gracza w fali, rozbija się.
    func testPlayerShockwaveWrecksRivalRammingFromBehind() {
        let len = 2000.0
        let def = CarCatalog.builtIn[0]
        let p = Car(name: "P", def: def, color: "#FFFFFF", isPlayer: true, startDistance: 104, startLane: 0, trackLength: len)
        let r = Car(name: "R", def: def, color: "#FFFFFF", isPlayer: false, startDistance: 100, startLane: 0, trackLength: len)
        p.speed = 40; r.speed = 45
        shockwave(p)
        let out = Collisions.resolve([p, r], trackLength: len)
        XCTAssertTrue(r.wrecked)
        XCTAssertFalse(p.wrecked)
        XCTAssertEqual(out.map(\.attacker.name), ["P"])
    }

    /// Fala rywala nie odbiera graczowi takedownu: gracz wjeżdżający mocno w rywala w fali dalej go rozbija.
    func testRivalShockwaveDoesNotStopPlayerTakedown() {
        let len = 2000.0
        let def = CarCatalog.builtIn[0]
        let r = Car(name: "R", def: def, color: "#FFFFFF", isPlayer: false, startDistance: 104, startLane: 0, trackLength: len)
        let p = Car(name: "P", def: def, color: "#FFFFFF", isPlayer: true, startDistance: 100, startLane: 0, trackLength: len)
        r.speed = 20; p.speed = 50
        shockwave(r)
        let out = Collisions.resolve([r, p], trackLength: len)
        XCTAssertTrue(r.wrecked)
        XCTAssertEqual(out.map(\.attacker.name), ["P"])
    }

    /// NITRO wciśnięte w trakcie rozbicia odpala się, gdy auto rusza (wcześniej wciśnięcie przepadało:
    /// rozbite auto nie czytało wejścia, a wciśnięcie to jednorazowe zbocze).
    func testNitroPressedWhileWreckedFiresOnRecovery() {
        let track = TrackData.makeCityLoop()
        let car = Car(name: "P", def: CarCatalog.builtIn[0], color: "#FFFFFF", isPlayer: true,
                      startDistance: 100, startLane: 0, trackLength: track.length)
        car.speed = 40
        car.nitro.gauge = 1
        car.wreck()
        let dt = 1.0 / 120
        car.step(dt: dt, input: CarInput(nitro: true), track: track)
        XCTAssertEqual(car.nitro.mode, .off)
        while car.wrecked { car.step(dt: dt, input: CarInput(), track: track) }
        car.events.removeAll()
        car.step(dt: dt, input: CarInput(), track: track)
        XCTAssertEqual(car.nitro.mode, .normal)
        XCTAssertTrue(car.events.contains { if case .nitro(.normal) = $0 { return true }; return false })
        // Jedno wciśnięcie — jedno nitro: po wygaśnięciu nic nie odpala się drugi raz.
        car.nitro.cancel()
        car.step(dt: dt, input: CarInput(), track: track)
        XCTAssertEqual(car.nitro.mode, .off)
    }
}
