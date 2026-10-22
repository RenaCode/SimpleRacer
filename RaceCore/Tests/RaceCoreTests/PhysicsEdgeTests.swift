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

    /// Próg `wreckImpact`: wbicie w bandę tuż poniżej progu tylko odbija auto, tuż powyżej — rozbija.
    func testWallWreckThreshold() {
        let track = TrackData.makeCityLoop()
        func hit(_ factor: Double) -> Car {
            let def = CarCatalog.builtIn[0]
            let c = Car(name: "T", def: def, color: "#FFFFFF", isPlayer: false, startDistance: 100,
                        startLane: track.halfWidth - def.shape.width / 2 - 0.01, trackLength: track.length)
            c.alphaVel = 0.5
            c.speed = Physics.wreckImpact / sin(c.alphaVel) * factor
            c.step(dt: RaceSim.step, input: CarInput(), track: track)
            return c
        }
        XCTAssertFalse(hit(0.95).wrecked)
        XCTAssertTrue(hit(1.05).wrecked)
    }

    /// Banda liczona z szerokości tego auta, nie ze stałej 2 m: szerokie auto zatrzymuje się dalej od krawędzi.
    func testWallUsesCarWidth() {
        let track = TrackData.makeCityLoop()
        var wide = CarCatalog.builtIn[0]
        wide.shape.width = 3.0
        let c = Car(name: "T", def: wide, color: "#FFFFFF", isPlayer: false, startDistance: 100,
                    startLane: track.halfWidth - 1.6, trackLength: track.length)
        c.speed = 30; c.alphaVel = 0.2
        for _ in 0..<60 { c.step(dt: RaceSim.step, input: CarInput(), track: track) }
        XCTAssertLessThanOrEqual(abs(c.d), track.halfWidth - wide.shape.width / 2 + 1e-9)
        // To samo dla rozbitego auta.
        let w = Car(name: "W", def: wide, color: "#FFFFFF", isPlayer: false, startDistance: 100,
                    startLane: track.halfWidth - 1.6, trackLength: track.length)
        w.speed = 30; w.alphaVel = 0.5
        w.wreck()
        for _ in 0..<60 { w.step(dt: RaceSim.step, input: CarInput(), track: track) }
        XCTAssertLessThanOrEqual(abs(w.d), track.halfWidth - wide.shape.width / 2 + 1e-9)
    }

    /// Dwaj rywale z dużą różnicą prędkości: zwykła wymiana prędkości, nikt nie rozbity
    /// (wcześniej przy różnicy > `rearTakedownDelta` prędkości zostawały bez zmian i tylny przenikał w przedni).
    func testRivalsRearHitExchangesSpeedWithoutWreck() {
        let len = 1000.0, def = CarCatalog.builtIn[0]
        let front = Car(name: "F", def: def, color: "#FFFFFF", isPlayer: false, startDistance: 104, startLane: 0, trackLength: len)
        let back = Car(name: "B", def: def, color: "#FFFFFF", isPlayer: false, startDistance: 100, startLane: 0, trackLength: len)
        front.speed = 20; back.speed = 50
        let out = Collisions.resolve([front, back], trackLength: len)
        XCTAssertTrue(out.isEmpty)
        XCTAssertFalse(front.wrecked || back.wrecked)
        XCTAssertEqual(back.speed, 34, accuracy: 1e-9)
        XCTAssertEqual(front.speed, 36, accuracy: 1e-9)
    }

    /// Rywal wjeżdżający w tył gracza: gracz nie rozbity, a jego prędkość rośnie najwyżej jak przy zwykłej
    /// wymianie (średnia + 1), nie do 90% prędkości rywala w jednym kroku.
    func testRivalRearHitGivesPlayerNoSpeedJump() {
        let len = 1000.0, def = CarCatalog.builtIn[0]
        let p = Car(name: "P", def: def, color: "#FFFFFF", isPlayer: true, startDistance: 104, startLane: 0, trackLength: len)
        let r = Car(name: "R", def: def, color: "#FFFFFF", isPlayer: false, startDistance: 100, startLane: 0, trackLength: len)
        p.speed = 20; r.speed = 64
        let out = Collisions.resolve([p, r], trackLength: len)
        XCTAssertTrue(out.isEmpty)
        XCTAssertFalse(p.wrecked || r.wrecked)
        XCTAssertLessThanOrEqual(p.speed, (20 + 64) / 2 + 1 + 1e-9)
        XCTAssertLessThan(r.speed, 64, "rywal oddaje prędkość, nie przenika przez gracza")
    }

    /// Rywal ocierający się mocno bokiem o wolnego gracza: bez rozbicia i bez zmiany prędkości gracza.
    func testRivalSideSlamGivesPlayerNoSpeedJump() {
        let len = 1000.0, def = CarCatalog.builtIn[0]
        let p = Car(name: "P", def: def, color: "#FFFFFF", isPlayer: true, startDistance: 100, startLane: 0, trackLength: len)
        let r = Car(name: "R", def: def, color: "#FFFFFF", isPlayer: false, startDistance: 100, startLane: 1.5, trackLength: len)
        p.speed = 20; r.speed = 60
        r.alphaVel = -0.5 // rywal wjeżdża bokiem w gracza
        let out = Collisions.resolve([p, r], trackLength: len)
        XCTAssertTrue(out.isEmpty)
        XCTAssertFalse(p.wrecked || r.wrecked)
        XCTAssertEqual(p.speed, 20, accuracy: 1e-9)
    }

    /// Dwaj rywale zderzający się mocno bokiem: tylko się odpychają.
    func testRivalsSideSlamNoWreck() {
        let len = 1000.0, def = CarCatalog.builtIn[0]
        let a = Car(name: "A", def: def, color: "#FFFFFF", isPlayer: false, startDistance: 100, startLane: 0, trackLength: len)
        let b = Car(name: "B", def: def, color: "#FFFFFF", isPlayer: false, startDistance: 100, startLane: 1.5, trackLength: len)
        a.speed = 50; b.speed = 50
        a.alphaVel = 0.4; b.alphaVel = -0.4
        let out = Collisions.resolve([a, b], trackLength: len)
        XCTAssertTrue(out.isEmpty)
        XCTAssertFalse(a.wrecked || b.wrecked)
        XCTAssertEqual(a.alphaVel, 0.2, accuracy: 1e-9)
        XCTAssertEqual(b.alphaVel, -0.2, accuracy: 1e-9)
    }

    private final class Brake: Controller {
        func read(car: Car, dt: Double, ctx: RaceContext) -> CarInput { CarInput(brake: true) }
    }

    /// Największe nakładanie się prostokątów jadącego auta z wrakiem (w poprzek, m) przy przejeździe obok.
    private func overlapPassingWreck(_ controller: Controller, isPlayer: Bool, speed: Double = 40, gap: Double = 140,
                                     lane: (Car) -> Double) -> Double {
        let track = TrackData.makeCityLoop()
        let def = CarCatalog.builtIn[0]
        let sim = RaceSim(track: track, entries: [
            Entry(name: "W", def: def, color: "#FFFFFF", isPlayer: false, controller: Brake()),
            Entry(name: "C", def: def, color: "#FFFFFF", isPlayer: isPlayer, controller: controller),
        ], laps: 5)
        let wreck = sim.cars[0], car = sim.cars[1]
        car.s = 60; car.distance = 60; car.d = 0; car.speed = speed
        wreck.s = 60 + gap; wreck.distance = 60 + gap; wreck.speed = 0
        sim.advance() // kontroler wybiera pas
        car.d = lane(car); wreck.d = car.d
        wreck.wreck(); wreck.wreckTimer = 30
        var worst = 0.0
        for _ in 0..<Int(4 / RaceSim.step) {
            sim.advance()
            sim.events.removeAll()
            let ds = abs(wrapDelta(car.s, wreck.s, track.length))
            let overS = (car.def.shape.length + wreck.def.shape.length) / 2 - ds
            let overD = (car.def.shape.width + wreck.def.shape.width) / 2 - abs(car.d - wreck.d)
            if overS > 0 && overD > 0 { worst = max(worst, overD) }
        }
        XCTAssertGreaterThan(car.distance, wreck.distance + 10, "auto minęło wrak")
        return worst
    }

    /// Przypadki: wrak widoczny z daleka, wrak, który pojawił się 30 m przed autem (0,75 s jazdy),
    /// i szybka jazda. Wrak bliżej niż ok. 0,5 s jazdy da się ominąć tylko częściowo (resztę robi `Collisions`).
    private let wreckCases: [(speed: Double, gap: Double)] = [(40, 140), (40, 30), (70, 50)]

    /// Rywal jadący prosto na wrak omija go z wyprzedzeniem, zamiast przenikać przez niego w ok. 0,2 s.
    func testRivalSteersAroundWreckAhead() {
        for c in wreckCases {
            let ai = AIController(skill: 0.9, rng: SeededRandom(seed: 7))
            let worst = overlapPassingWreck(ai, isPlayer: false, speed: c.speed, gap: c.gap) { _ in ai.lane }
            print(String(format: "rywal przy wraku (%.0f m/s, %.0f m): nakładanie %.2f m", c.speed, c.gap, worst))
            XCTAssertEqual(worst, 0, accuracy: 0.05, "\(c)")
        }
    }

    /// Auto-prowadzenie gracza też omija wrak na swoim pasie.
    func testAutopilotSteersAroundWreckAhead() {
        for c in wreckCases {
            let worst = overlapPassingWreck(AutoSteerController(input: FakeInput()), isPlayer: true,
                                            speed: c.speed, gap: c.gap) { _ in 0 }
            print(String(format: "auto-prowadzenie przy wraku (%.0f m/s, %.0f m): nakładanie %.2f m", c.speed, c.gap, worst))
            XCTAssertEqual(worst, 0, accuracy: 0.05, "\(c)")
        }
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
