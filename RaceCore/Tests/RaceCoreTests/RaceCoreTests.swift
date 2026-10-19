import XCTest
@testable import RaceCore

final class MathTests: XCTestCase {
    func testWrap() {
        XCTAssertEqual(wrap(-1, 10), 9)
        XCTAssertEqual(wrap(25, 10), 5)
        XCTAssertEqual(wrapDelta(1, 99, 100), 2, accuracy: 1e-9)
        XCTAssertEqual(wrapDelta(99, 1, 100), -2, accuracy: 1e-9)
        XCTAssertEqual(wrapAngle(2 * .pi + 0.1), 0.1, accuracy: 1e-9)
    }
}

final class NitroTests: XCTestCase {
    private func run(_ n: Nitro, _ seconds: Double, dt: Double = 1.0 / 120) {
        var t = 0.0
        while t < seconds { n.update(dt: dt, pressed: false); t += dt }
    }

    func testNoActivationOnEmptyGauge() {
        let n = Nitro()
        n.gauge = 0.05
        XCTAssertNil(n.update(dt: 0.01, pressed: true))
        XCTAssertEqual(n.mode, .off)
    }

    func testNormalBurnsOut() {
        let n = Nitro()
        n.gauge = 1
        XCTAssertEqual(n.update(dt: 0.01, pressed: true), .normal)
        run(n, NitroConfig.burnTime)
        XCTAssertEqual(n.mode, .off)
    }

    func testPerfectOnlyInWindow() {
        let n = Nitro()
        n.gauge = 1
        n.update(dt: 0.01, pressed: true)
        run(n, 0.5)
        XCTAssertNil(n.update(dt: 0.01, pressed: true))
        run(n, NitroConfig.burnTime - 0.5 - NitroConfig.perfectWindow + 0.1)
        XCTAssertTrue(n.inPerfectWindow)
        XCTAssertEqual(n.update(dt: 0.01, pressed: true), .perfect)
        XCTAssertEqual(n.boost, NitroConfig.boost(.perfect))
    }

    func testDoubleTapShockwaveDrainsGauge() {
        let n = Nitro()
        n.gauge = 1
        n.update(dt: 0.01, pressed: true)
        run(n, 0.1)
        XCTAssertEqual(n.update(dt: 0.01, pressed: true), .shockwave)
        run(n, NitroConfig.shockwaveTime + 0.1)
        XCTAssertEqual(n.mode, .off)
        XCTAssertLessThan(n.gauge, 0.01)
    }
}

final class TrackTests: XCTestCase {
    let track = TrackData.makeCityLoop()

    func testLoopTurnsFullCircle() {
        var total = 0.0
        var s = 0.0
        while s < track.length { total += track.sample(at: s).curvature * track.ds; s += track.ds }
        XCTAssertEqual(abs(total), 2 * .pi, accuracy: 0.05)
    }

    func testNoCornerTighterThan30m() {
        var maxK = 0.0
        var s = 0.0
        while s < track.length { maxK = max(maxK, abs(track.sample(at: s).curvature)); s += track.ds }
        XCTAssertGreaterThan(1 / maxK, 30)
    }

    func testPositiveOffsetIsLeft() {
        let c = track.toWorld(s: 10, d: 0)
        let l = track.toWorld(s: 10, d: 5)
        let fx = sin(c.heading), fz = cos(c.heading)
        // Iloczyn wektorowy (przód × w bok) w osi Y > 0 oznacza lewo przy osi Y w górę.
        XCTAssertGreaterThan(fz * (l.x - c.x) - fx * (l.z - c.z), 0)
    }
}

final class RaceSimTests: XCTestCase {
    /// Sześć aut AI kończy wyścig w rozsądnym czasie i nie rozbija się o bandy.
    func testAIFinishesWithoutWallWrecks() {
        let track = TrackData.makeCityLoop()
        let rng = SeededRandom(seed: 7)
        let entries = (0..<6).map { (i: Int) -> Entry in
            Entry(name: "AI \(i)", def: CarCatalog.all[i % CarCatalog.all.count], color: "#FFFFFF",
                  isPlayer: i == 5,
                  controller: AIController(skill: 0.92 + rng.next() * 0.06, rng: SeededRandom(seed: UInt64(100 + i))))
        }
        let sim = RaceSim(track: track, entries: entries, laps: 2)
        var wrecks = 0, takedowns = 0
        while sim.finishOrder.count < 6 && sim.time < 240 {
            sim.advance()
            for e in sim.events {
                if case .wreck = e { wrecks += 1 }
                if case .takedown = e { takedowns += 1 }
            }
            sim.events.removeAll()
        }
        print(String(format: "trasa %.0f m, meta po %.1f s, rozbicia %d (w tym takedowny %d)",
                     track.length, sim.time, wrecks, takedowns))
        XCTAssertEqual(sim.finishOrder.count, 6)
        XCTAssertLessThan(sim.time, 120)
        XCTAssertEqual(wrecks - takedowns, 0, "żadnego rozbicia o bandę")
    }
}

final class DriftTests: XCTestCase {
    let track = TrackData.makeCityLoop()

    private func car(at s: Double, speed: Double) -> Car {
        let c = Car(name: "T", def: CarCatalog.all[0], color: "#FFFFFF", isPlayer: true,
                    startDistance: s, startLane: 0, trackLength: track.length)
        c.speed = speed
        return c
    }

    private func drive(_ c: Car, seconds: Double, input: CarInput) {
        var t = 0.0
        while t < seconds { c.step(dt: RaceSim.step, input: input, track: track); t += RaceSim.step }
    }

    /// Przycisk DRIFT bez skrętu wchodzi w poślizg zamiast hamować.
    func testDriftButtonAloneDriftsInsteadOfBraking() {
        let c = car(at: 50, speed: 60)
        drive(c, seconds: 0.4, input: CarInput(steer: 0, drift: true))
        XCTAssertTrue(c.drifting)
        XCTAssertGreaterThan(c.speed, 50, "drift nie może działać jak hamulec")
        XCTAssertNotEqual(c.slide, 0)
    }

    /// Wciśnięcie DRIFT przed skrętem też daje drift (kolejność przycisków nie ma znaczenia).
    func testDriftThenSteerStillDrifts() {
        let c = car(at: 50, speed: 60)
        drive(c, seconds: 0.2, input: CarInput(steer: 0, drift: true))
        drive(c, seconds: 0.15, input: CarInput(steer: 0.4, drift: true))
        XCTAssertTrue(c.drifting)
        XCTAssertGreaterThan(c.speed, 50)
    }

    /// Bez skrętu poślizg idzie w stronę najbliższego zakrętu.
    func testDriftDirectionFollowsUpcomingCorner() {
        // Szukamy miejsca, za którym trasa wyraźnie skręca.
        var s = 0.0, found = false, expected = 0.0
        while s < track.length && !found {
            var sum = 0.0
            var k = 20.0
            while k <= 80 { sum += track.sample(at: s + k).curvature; k += 5 }
            if abs(sum) > 0.05 { found = true; expected = sum > 0 ? 1 : -1 } else { s += 10 }
        }
        XCTAssertTrue(found)
        let c = car(at: s, speed: 60)
        drive(c, seconds: 0.1, input: CarInput(steer: 0, drift: true))
        XCTAssertEqual(c.slide > 0 ? 1.0 : -1.0, expected)
    }

    /// Przycisk DRIFT nigdy nie hamuje: przy małej prędkości auto dalej przyspiesza,
    /// a drift włącza się sam po osiągnięciu prędkości (dzieci często trzymają przycisk od startu).
    func testDriftButtonNeverBrakesAndKicksInAtSpeed() {
        let c = car(at: 50, speed: 5)
        drive(c, seconds: 0.5, input: CarInput(steer: 0, drift: true))
        XCTAssertGreaterThan(c.speed, 5, "przyspiesza mimo wciśniętego DRIFT")
        XCTAssertFalse(c.drifting)
        drive(c, seconds: 3, input: CarInput(steer: 0, drift: true))
        XCTAssertTrue(c.drifting, "po rozpędzeniu drift sam się włącza")
    }

    /// Krótkie stuknięcie DRIFT daje drift trwający co najmniej `Physics.driftMinTime`.
    func testTapDriftLastsMinimumTime() {
        let c = car(at: 50, speed: 60)
        drive(c, seconds: 0.05, input: CarInput(steer: 0, drift: true))
        // Stałe czasy (nie z `driftMinTime`), żeby test łapał też zbyt krótki drift.
        drive(c, seconds: 0.3, input: CarInput(steer: 0, drift: false))
        XCTAssertTrue(c.drifting, "stuknięcie nie kończy driftu od razu")
        drive(c, seconds: 0.5, input: CarInput(steer: 0, drift: false))
        XCTAssertFalse(c.drifting, "po minimalnym czasie drift się kończy")
    }
}

final class PickupTests: XCTestCase {
    /// Butle leżą na trasie, w jej granicach i nie pod stawką startową.
    func testLayoutStaysOnTrack() {
        let track = TrackData.makeCityLoop()
        let pickups = Pickups.layout(track: track)
        XCTAssertGreaterThan(pickups.count, 20)
        for p in pickups {
            XCTAssertLessThan(abs(p.d), track.halfWidth - Physics.carWidth / 2)
            XCTAssertGreaterThan(p.s, 50)
            XCTAssertLessThan(p.s, track.length - 30)
        }
    }

    /// Przejazd przez butlę dolewa nitro, butla znika i po czasie wraca.
    func testDrivingThroughPickupAddsNitroAndRespawns() {
        let track = TrackData.makeCityLoop()
        let target = Pickups.layout(track: track)[0]

        /// Kontroler trzymający auto na pasie butli.
        final class HoldLane: Controller {
            let lane: Double
            init(lane: Double) { self.lane = lane }
            func read(car: Car, dt: Double, ctx: RaceContext) -> CarInput {
                car.d = lane
                car.alphaVel = 0
                return CarInput()
            }
        }
        let sim = RaceSim(track: track, entries: [
            Entry(name: "P", def: CarCatalog.all[0], color: "#FFFFFF", isPlayer: true, controller: HoldLane(lane: target.d)),
        ])
        let car = sim.cars[0]
        car.nitro.gauge = 0
        var collected = 0
        while sim.time < 15 && car.distance < target.s + 30 {
            sim.advance()
            for e in sim.events { if case .pickup = e { collected += 1 } }
            sim.events.removeAll()
        }
        XCTAssertEqual(collected, Physics.pickupsPerGroup, "cała seria na tym pasie")
        XCTAssertEqual(car.nitro.gauge, Physics.pickupNitro * Double(Physics.pickupsPerGroup), accuracy: 1e-9)
        XCTAssertFalse(sim.pickups[0].isActive)
        for _ in 0..<Int((Physics.pickupRespawn + 0.1) / RaceSim.step) { sim.advance() }
        XCTAssertTrue(sim.pickups[0].isActive)
    }
}

final class ObjModelTests: XCTestCase {
    func testParsesGroupsMaterialsAndTriangulates() {
        let obj = """
        mtllib car.mtl
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        vt 0 0
        vt 1 0
        vt 1 1
        vt 0 1
        vn 0 0 1
        g body
        usemtl paint
        f 1/1/1 2/2/1 3/3/1 4/4/1
        g wheel-front-left
        usemtl rubber
        f 1/1/1 2/2/1 3/3/1
        """
        let m = ObjModel.parse(obj)
        XCTAssertEqual(m.materialLibrary, "car.mtl")
        XCTAssertEqual(m.groups.map(\.name), ["body", "wheel-front-left"])
        let body = m.group(named: "body")!.parts[0]
        XCTAssertEqual(body.material, "paint")
        XCTAssertEqual(body.indices.count, 6, "czworokąt → 2 trójkąty")
        XCTAssertEqual(body.positions.count, 4)
        XCTAssertEqual(body.uvs.count, 4)
        XCTAssertEqual(body.normals.count, 4)
        XCTAssertEqual(m.bounds.max, [1, 1, 0])
    }

    func testParsesMaterialLibrary() {
        let mats = ObjModel.parseMaterials("""
        newmtl colormap
        Kd 1 1 1
        map_Kd Textures/colormap.png
        newmtl red
        Kd 0.9 0.3 0.3
        """)
        XCTAssertEqual(mats["colormap"]?.texture, "Textures/colormap.png")
        XCTAssertEqual(mats["red"]?.diffuse, [0.9, 0.3, 0.3])
        XCTAssertNil(mats["red"]?.texture)
    }

    /// Katalog z modelami aplikacji (App/Models) względem tego pliku.
    private var modelsDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../App/Models").standardized
    }

    /// Każdy model w aplikacji się wczytuje, a jego materiały i tekstury istnieją.
    func testAllBundledModelsLoad() throws {
        let fm = FileManager.default
        var count = 0
        for dir in ["Cars", "City", "Track"] {
            let folder = modelsDir.appendingPathComponent(dir)
            for file in try fm.contentsOfDirectory(atPath: folder.path) where file.hasSuffix(".obj") {
                let model = ObjModel.parse(try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8))
                XCTAssertFalse(model.groups.isEmpty, file)
                let lib = try XCTUnwrap(model.materialLibrary, file)
                let mats = ObjModel.parseMaterials(try String(contentsOf: folder.appendingPathComponent(lib), encoding: .utf8))
                for g in model.groups { for p in g.parts {
                    XCTAssertNotNil(mats[p.material], "\(file): brak materiału \(p.material)")
                    if let tex = mats[p.material]?.texture {
                        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent(tex).path), "\(file): brak \(tex)")
                        XCTAssertFalse(p.uvs.isEmpty, "\(file): tekstura bez UV")
                    }
                } }
                count += 1
            }
        }
        // 3 auta, 19 budynków, 2 drzewa toru (zapasowe modele Kenney).
        XCTAssertEqual(count, 3 + 19 + 2)
    }

    /// Każde auto ma nadwozie i cztery koła, a wskazane pole palety naprawdę jest jego lakierem.
    func testCarModelsHaveWheelsAndPaintCell() throws {
        for car in CarCatalog.all {
            let ref = try XCTUnwrap(car.model)
            let url = modelsDir.appendingPathComponent("Cars/\(ref.file).obj")
            let model = ObjModel.parse(try String(contentsOf: url, encoding: .utf8))
            for w in ["wheel-front-left", "wheel-front-right", "wheel-back-left", "wheel-back-right"] {
                XCTAssertNotNil(model.group(named: w), "\(ref.file): brak \(w)")
            }
            let body = try XCTUnwrap(model.group(named: "body"))
            let uvs = body.parts.flatMap(\.uvs)
            let inCell = uvs.filter { uv in
                let u = uv.x - uv.x.rounded(.down), v = uv.y - uv.y.rounded(.down)
                return min(7, Int(u * 8)) == ref.paintColumn && min(3, Int((1 - v) * 4)) == ref.paintRow
            }
            XCTAssertGreaterThan(Double(inCell.count) / Double(uvs.count), 0.1, "\(ref.file): pole lakieru nieużywane")
        }
    }
}

/// Atrapa wejścia gracza: stały skręt/drift, nitro na żądanie.
final class FakeInput: PlayerInputSource {
    var steer = 0.0
    var drift = false
    var nitroQueued = false
    func consumeNitro() -> Bool { defer { nitroQueued = false }; return nitroQueued }
}

final class AutoSteerTests: XCTestCase {
    private func race(player controller: Controller, seconds: Double, laps: Int = 2,
                      during: ((RaceSim) -> Void)? = nil) -> (sim: RaceSim, wallWrecks: Int) {
        let track = TrackData.makeCityLoop()
        let sim = RaceSim(track: track, entries: [
            Entry(name: "Gracz", def: CarCatalog.all[0], color: "#FFFFFF", isPlayer: true, controller: controller),
        ], laps: laps)
        var wrecks = 0
        while sim.time < seconds && sim.finishOrder.isEmpty {
            sim.advance()
            during?(sim)
            for e in sim.events { if case .wreck = e { wrecks += 1 } }
            sim.events.removeAll()
        }
        return (sim, wrecks)
    }

    /// Bez dotykania czegokolwiek auto-prowadzenie przejeżdża cały wyścig i nie rozbija się o bandy.
    func testAutopilotFinishesRaceWithoutWallWrecks() {
        let (sim, wrecks) = race(player: AutoSteerController(input: FakeInput()), seconds: 120)
        XCTAssertEqual(sim.finishOrder.count, 1, "auto-prowadzenie dojechało do mety")
        XCTAssertEqual(wrecks, 0)
    }

    /// Auto-prowadzenie naprawdę prowadzi: prawie nie dotyka band, a auto bez sterowania ociera się o nie
    /// przez dużą część okrążenia (kontrola, że pomiar coś rozróżnia).
    func testAutopilotStaysOffTheWalls() {
        func wallShare(_ controller: Controller) -> Double {
            var touching = 0, total = 0
            _ = race(player: controller, seconds: 60, laps: 1) { sim in
                let car = sim.cars[0]
                total += 1
                if abs(car.d) >= sim.track.halfWidth - Physics.carWidth / 2 - 0.05 { touching += 1 }
            }
            return Double(touching) / Double(max(1, total))
        }
        let auto = wallShare(AutoSteerController(input: FakeInput()))
        let none = wallShare(PlayerController(input: FakeInput()))
        print(String(format: "czas przy bandzie: auto-prowadzenie %.0f%%, bez sterowania %.0f%%", auto * 100, none * 100))
        XCTAssertLessThan(auto, 0.02)
        XCTAssertGreaterThan(none, 0.2)
    }

    /// Jedno stuknięcie ◀ przestawia auto na lewy pas.
    func testTapLeftMovesOneLaneLeft() {
        let input = FakeInput()
        let ctl = AutoSteerController(input: input)
        var tapped = false
        let (sim, _) = race(player: ctl, seconds: 8) { sim in
            if !tapped && sim.time > 2 { input.steer = 1; tapped = true } else { input.steer = 0 }
        }
        let car = sim.cars[0]
        XCTAssertEqual(car.d, 0.55 * sim.track.halfWidth, accuracy: 1.5)
    }
}

final class DriftDirectionTests: XCTestCase {
    let track = TrackData.makeCityLoop()

    /// Miejsce, za którym trasa wyraźnie skręca w stronę `dir` (+1 lewo, −1 prawo).
    private func spot(turning dir: Double) -> Double {
        var s = 0.0
        while s < track.length {
            var sum = 0.0
            var k = 20.0
            while k <= 80 { sum += track.sample(at: s + k).curvature; k += 5 }
            if sum * dir > 0.05 { return s }
            s += 10
        }
        XCTFail("brak zakrętu w stronę \(dir)")
        return 0
    }

    /// DRIFT wciśnięty bez skrętu przed zakrętem w prawo, a potem pełny skręt w lewo:
    /// poślizg ma przejść na lewo (jak w grach mobilnych — kierunek driftu idzie za kierownicą).
    func testDriftFollowsSteeringToOtherSide() {
        let c = Car(name: "T", def: CarCatalog.all[0], color: "#FFFFFF", isPlayer: true,
                    startDistance: spot(turning: -1), startLane: 0, trackLength: track.length)
        c.speed = 60
        var t = 0.0
        while t < 0.1 { c.step(dt: RaceSim.step, input: CarInput(steer: 0, drift: true), track: track); t += RaceSim.step }
        XCTAssertLessThan(c.slide, 0, "start w prawo, zgodnie z zakrętem")
        t = 0
        while t < 0.35 { c.step(dt: RaceSim.step, input: CarInput(steer: 1, drift: true), track: track); t += RaceSim.step }
        XCTAssertTrue(c.drifting)
        XCTAssertGreaterThan(c.slide, 0, "po skręcie w lewo poślizg w lewo")
    }

    /// Drift działa w obie strony także od początku: skręt w lewo / w prawo przy wciśnięciu DRIFT.
    func testDriftBothDirectionsFromStart() {
        for dir in [1.0, -1.0] {
            let c = Car(name: "T", def: CarCatalog.all[0], color: "#FFFFFF", isPlayer: true,
                        startDistance: 50, startLane: 0, trackLength: track.length)
            c.speed = 60
            var t = 0.0
            while t < 0.2 { c.step(dt: RaceSim.step, input: CarInput(steer: dir, drift: true), track: track); t += RaceSim.step }
            XCTAssertEqual(c.slide > 0 ? 1.0 : -1.0, dir)
        }
    }
}

final class ArcadePhysicsTests: XCTestCase {
    let track = TrackData.makeCityLoop()

    private func car(at s: Double = 50, speed: Double, lane: Double = 0) -> Car {
        let c = Car(name: "T", def: CarCatalog.builtIn[0], color: "#FFFFFF", isPlayer: true,
                    startDistance: s, startLane: lane, trackLength: track.length)
        c.speed = speed
        return c
    }

    private func drive(_ c: Car, _ seconds: Double, _ input: CarInput) {
        var t = 0.0
        while t < seconds { c.step(dt: RaceSim.step, input: input, track: track); t += RaceSim.step }
    }

    /// Przy dużej prędkości ten sam skręt obraca auto wolniej niż przy średniej — stabilność.
    func testSteeringSoftensAtHighSpeed() {
        let mid = car(speed: 30), fast = car(speed: 75)
        XCTAssertLessThan(fast.yawRatePerSteer, mid.yawRatePerSteer)
        XCTAssertGreaterThan(fast.yawRatePerSteer, mid.yawRatePerSteer * 0.6, "ale nadal da się skręcać")
    }

    /// Długi drift po puszczeniu daje zryw (mini-turbo); krótki — nie.
    func testLongDriftGivesMiniTurbo() {
        func release(after seconds: Double) -> (boost: Double, events: Int) {
            let c = car(speed: 55)
            drive(c, seconds, CarInput(steer: 0, drift: true))
            c.events.removeAll()
            drive(c, RaceSim.step, CarInput(steer: 0, drift: false))
            let n = c.events.filter { if case .driftBoost = $0 { return true }; return false }.count
            return (c.driftBoostTimer, n)
        }
        let short = release(after: 0.3), long = release(after: 1.6)
        XCTAssertEqual(short.events, 0)
        XCTAssertEqual(long.events, 1)
        XCTAssertGreaterThan(long.boost, 0.5)
    }

    /// Za rywalem w tym samym pasie auto łapie slipstream i dogania go; obok — nie.
    func testSlipstreamPullsCarBehindCloser() {
        func gapAfter(lane: Double) -> Double {
            let leader = AutoSteerController(input: FakeInput())
            let sim = RaceSim(track: track, entries: [
                Entry(name: "A", def: CarCatalog.builtIn[0], color: "#FFFFFF", isPlayer: false, controller: leader),
                Entry(name: "B", def: CarCatalog.builtIn[0], color: "#FFFFFF", isPlayer: true, controller: AutoSteerController(input: FakeInput())),
            ], laps: 5)
            let a = sim.cars[0], b = sim.cars[1]
            a.s = 120; a.distance = 120; a.d = 0; a.speed = 73
            b.s = 105; b.distance = 105; b.d = lane; b.speed = 73
            var t = 0.0
            while t < 4.0 { sim.advance(); t += RaceSim.step }
            return a.distance - b.distance
        }
        let behind = gapAfter(lane: 0), aside = gapAfter(lane: 5)
        print(String(format: "odstęp po 4 s: w slipstreamie %.1f m, obok %.1f m", behind, aside))
        XCTAssertLessThan(behind, aside - 1, "slipstream skraca odstęp")
    }

    /// Muśnięcie bandy pod małym kątem prawie nie zabiera prędkości.
    func testGlancingWallContactIsCheap() {
        let c = car(speed: 60, lane: track.halfWidth - Physics.carWidth / 2 - 0.05)
        c.alphaVel = 0.08 // lekko w stronę lewej bandy
        let before = c.speed
        drive(c, 0.2, CarInput(steer: 0))
        XCTAssertFalse(c.wrecked)
        XCTAssertGreaterThan(c.speed, before * 0.93)
    }

    /// Uderzenie w bandę pod kątem (bez rozbicia) zgłasza zdarzenie z prędkością wbicia.
    func testWallHitEmitsEvent() {
        let c = car(speed: 40, lane: track.halfWidth - Physics.carWidth / 2 - 0.05)
        c.alphaVel = 0.3
        var hit: Double?
        for _ in 0..<30 {
            c.step(dt: RaceSim.step, input: CarInput(steer: 0), track: track)
            for e in c.events { if case let .wallHit(v) = e { hit = v } }
            c.events.removeAll()
        }
        XCTAssertFalse(c.wrecked)
        XCTAssertNotNil(hit)
        XCTAssertGreaterThan(hit ?? 0, Physics.wallHitMin)
    }

    /// Po rozbiciu auto rusza bez skoku prędkości.
    func testWreckRestartHasNoSpeedJump() {
        let c = car(speed: 60)
        c.wreck()
        var last = c.speed
        var maxJump = 0.0
        for _ in 0..<Int(3 / RaceSim.step) {
            c.step(dt: RaceSim.step, input: CarInput(steer: 0), track: track)
            maxJump = max(maxJump, c.speed - last)
            last = c.speed
        }
        XCTAssertFalse(c.wrecked)
        XCTAssertLessThan(maxJump, Physics.wreckRestartSpeed + 1)
    }

    /// Odpalenie nitro daje natychmiastowego „kopa”.
    func testNitroGivesInstantKick() {
        let c = car(speed: 50)
        c.nitro.gauge = 1
        drive(c, RaceSim.step, CarInput(nitro: true))
        XCTAssertGreaterThan(c.speed, 50 + Physics.nitroKick * 0.9)
    }
}

final class TrackCatalogTests: XCTestCase {
    func testFortyValidTracksInFiveRegions() {
        XCTAssertEqual(TrackCatalog.all.count, 40)
        for r in Region.allCases {
            XCTAssertEqual(TrackCatalog.all.filter { $0.region == r }.count, 8, r.name)
        }
        for spec in TrackCatalog.all {
            XCTAssertEqual(TrackValidator.problems(spec.makeTrack()), [], "trasa \(spec.id) \(spec.name)")
        }
        XCTAssertEqual(Set(TrackCatalog.all.map(\.name)).count, 40, "nazwy unikalne")
    }

    /// Walidator naprawdę odrzuca złe trasy (kontrola, że test powyżej coś sprawdza).
    func testValidatorRejectsBadTracks() {
        let hairpin: [SIMD2<Double>] = [[0, 0], [300, 0], [310, 20], [0, 25]]
        XCTAssertFalse(TrackValidator.problems(Track(points: hairpin, halfWidth: 9)).isEmpty)
        let tiny: [SIMD2<Double>] = [[0, 0], [100, 0], [100, 100], [0, 100]]
        XCTAssertFalse(TrackValidator.problems(Track(points: tiny, halfWidth: 9)).isEmpty)
    }

    /// Trudność rośnie łagodnie (gra dla dzieci): najwyżej 2 okrążenia, jezdnia zawsze szeroka.
    func testDifficultyGrowsGently() {
        let first = TrackCatalog.all.first!, last = TrackCatalog.all.last!
        XCTAssertLessThan(first.difficulty, last.difficulty)
        XCTAssertTrue(TrackCatalog.all.allSatisfy { $0.laps <= 2 })
        XCTAssertTrue(TrackCatalog.all.allSatisfy { $0.halfWidth >= 8.5 })
        XCTAssertLessThan(last.halfWidth, first.halfWidth)
    }

    /// Na każdej z 40 tras sześć aut AI przejeżdża okrążenie bez rozbicia o bandę.
    func testAIDrivesEveryTrackCleanly() {
        for spec in TrackCatalog.all {
            let track = spec.makeTrack()
            let entries = (0..<6).map { (i: Int) -> Entry in
                Entry(name: "AI \(i)", def: CarCatalog.builtIn[i % 3], color: "#FFFFFF", isPlayer: i == 5,
                      controller: AIController(skill: 0.95, rng: SeededRandom(seed: UInt64(i) + UInt64(spec.id) * 10)))
            }
            let sim = RaceSim(track: track, entries: entries, laps: 1)
            var wrecks = 0, takedowns = 0
            while sim.finishOrder.count < 6 && sim.time < 200 {
                sim.advance()
                for e in sim.events {
                    if case .wreck = e { wrecks += 1 }
                    if case .takedown = e { takedowns += 1 }
                }
                sim.events.removeAll()
            }
            XCTAssertEqual(sim.finishOrder.count, 6, "trasa \(spec.id): nie wszyscy dojechali")
            XCTAssertEqual(wrecks - takedowns, 0, "trasa \(spec.id) \(spec.name): rozbicia o bandę")
        }
    }

    /// Klasyfikacja: auta na mecie w kolejności przyjazdu, przed wszystkimi, które jeszcze jadą;
    /// zdarzenie mety podaje to samo miejsce co `position(of:)`.
    func testStandingsFollowFinishOrder() {
        let spec = TrackCatalog.all[0]
        let entries = (0..<6).map { (i: Int) -> Entry in
            Entry(name: "AI \(i)", def: CarCatalog.builtIn[i % 3], color: "#FFFFFF", isPlayer: i == 5,
                  controller: AIController(skill: 0.8 + Double(i) * 0.03, rng: SeededRandom(seed: UInt64(i) + 7)))
        }
        let sim = RaceSim(track: spec.makeTrack(), entries: entries, laps: 1)
        var reported: [ObjectIdentifier: Int] = [:]
        while sim.finishOrder.count < 3 && sim.time < 200 {
            sim.advance()
            for e in sim.events { if case let .finish(car, position) = e { reported[ObjectIdentifier(car)] = position } }
            sim.events.removeAll()
        }
        XCTAssertEqual(sim.finishOrder.count, 3)
        let standings = sim.standings()
        for (i, car) in sim.finishOrder.enumerated() {
            XCTAssertTrue(standings[i] === car, "meta \(i + 1) na swoim miejscu")
            XCTAssertEqual(sim.position(of: car), i + 1)
            XCTAssertEqual(reported[ObjectIdentifier(car)], i + 1)
        }
        XCTAssertTrue(standings.dropFirst(3).allSatisfy { !$0.finished })
    }
}

final class CampaignTests: XCTestCase {
    let starter = CarCatalog.car(id: Campaign.starterCar)
    let maxed: [Upgrade: Int] = Dictionary(uniqueKeysWithValues: Upgrade.allCases.map { ($0, Campaign.maxLevel) })

    func testNextTrackIsFirstUnplayedOpenTrack() {
        var state = Campaign.newGame()
        XCTAssertEqual(Campaign.nextTrack(state).id, 1)
        state.bestStars[1] = 2
        state.bestStars[2] = 3
        XCTAssertEqual(Campaign.nextTrack(state).id, 3)
        // Cała pierwsza kraina zaliczona, a na drugą brak gwiazdek: zostaje ostatnia dostępna.
        for id in 1...TrackCatalog.perRegion { state.bestStars[id] = 1 }
        XCTAssertLessThan(state.totalStars, Campaign.starsToUnlock[1])
        XCTAssertEqual(Campaign.nextTrack(state).id, TrackCatalog.perRegion)
    }

    func testUpgradesRaiseRating() {
        let base = Campaign.rating(starter)
        let one = Campaign.rating(Campaign.upgraded(starter, levels: [.engine: 1]))
        let full = Campaign.rating(Campaign.upgraded(starter, levels: maxed))
        XCTAssertGreaterThan(one, base)
        XCTAssertGreaterThan(full, one)
    }

    /// Łatwo dla dzieci: auto startowe po pełnym ulepszeniu przejdzie każdą trasę,
    /// a na pierwsze trasy wystarczy bez ulepszeń.
    func testStarterCarCanFinishWholeCampaign() {
        let full = Campaign.rating(Campaign.upgraded(starter, levels: maxed))
        let hardest = TrackCatalog.all.map(Campaign.requiredRating).max()!
        XCTAssertGreaterThanOrEqual(full, hardest)
        XCTAssertGreaterThanOrEqual(Campaign.rating(starter), Campaign.requiredRating(TrackCatalog.all[0]))
        let freeTracks = TrackCatalog.all.filter { Campaign.rating(starter) >= Campaign.requiredRating($0) }.count
        XCTAssertGreaterThanOrEqual(freeTracks, 8, "cała pierwsza kraina bez ulepszeń")
    }

    /// Monety z jednego przejścia kampanii (nawet na 3. miejscach) starczą na pełne ulepszenie auta startowego.
    func testOnePlaythroughPaysForFullUpgrade() {
        let earned = TrackCatalog.all.map { Campaign.reward($0, place: 3, takedowns: 0) }.reduce(0, +)
        let cost = Upgrade.allCases.count * (1...Campaign.maxLevel).map(Campaign.upgradeCost).reduce(0, +)
        XCTAssertGreaterThanOrEqual(earned, cost)
    }

    func testStarsAndRewards() {
        XCTAssertEqual(Campaign.stars(place: 1), 3)
        XCTAssertEqual(Campaign.stars(place: 3), 2)
        XCTAssertEqual(Campaign.stars(place: 6), 1, "każde dojechanie daje gwiazdkę")
        let spec = TrackCatalog.all[10]
        XCTAssertGreaterThan(Campaign.reward(spec, place: 1, takedowns: 0), Campaign.reward(spec, place: 2, takedowns: 0))
        XCTAssertGreaterThan(Campaign.reward(spec, place: 6, takedowns: 0), 0)
        XCTAssertGreaterThan(Campaign.reward(spec, place: 2, takedowns: 2), Campaign.reward(spec, place: 2, takedowns: 0))
    }

    func testRecordKeepsBestStarsAndAddsCoins() {
        var st = Campaign.newGame()
        let spec = TrackCatalog.all[0]
        let a = Campaign.record(spec, place: 2, takedowns: 0, &st)
        let b = Campaign.record(spec, place: 5, takedowns: 0, &st)
        XCTAssertTrue(a.newBest)
        XCTAssertFalse(b.newBest)
        XCTAssertEqual(st.bestStars[spec.id], 2)
        XCTAssertEqual(st.coins, a.coins + b.coins)
    }

    func testUnlockingProgression() {
        var st = Campaign.newGame()
        let t1 = TrackCatalog.all[0], t2 = TrackCatalog.all[1], coast1 = TrackCatalog.all[8]
        XCTAssertTrue(Campaign.isUnlocked(t1, st))
        XCTAssertFalse(Campaign.isUnlocked(t2, st), "kolejna trasa po ukończeniu poprzedniej")
        Campaign.record(t1, place: 6, takedowns: 0, &st)
        XCTAssertTrue(Campaign.isUnlocked(t2, st))
        XCTAssertFalse(Campaign.isUnlocked(coast1, st), "kraina za gwiazdki")
        for spec in TrackCatalog.all.prefix(8) { Campaign.record(spec, place: 2, takedowns: 0, &st) }
        XCTAssertGreaterThanOrEqual(st.totalStars, Campaign.starsToUnlock[1])
        XCTAssertTrue(Campaign.isUnlocked(coast1, st), "8 tras na podium otwiera Wybrzeże")
    }

    func testBuyingUpgradesAndCars() throws {
        var st = Campaign.newGame()
        XCTAssertThrowsError(try Campaign.buyUpgrade(.engine, car: Campaign.starterCar, &st))
        st.coins = 1000
        try Campaign.buyUpgrade(.engine, car: Campaign.starterCar, &st)
        XCTAssertEqual(st.level(.engine, car: Campaign.starterCar), 1)
        XCTAssertEqual(st.coins, 1000 - Campaign.upgradeCost(toLevel: 1))
        XCTAssertThrowsError(try Campaign.buyUpgrade(.engine, car: "grom", &st), "nie można ulepszać cudzego auta")
        let grom = CarCatalog.car(id: "grom")
        st.coins = Campaign.price(of: grom)
        try Campaign.buyCar(grom, &st)
        XCTAssertTrue(st.ownedCars.contains("grom"))
        XCTAssertEqual(st.coins, 0)
    }

    func testStateSurvivesSaving() throws {
        var st = Campaign.newGame()
        st.coins = 321
        st.bestStars[3] = 2
        st.upgrades["strzala"] = [.nitro: 2]
        let back = try JSONDecoder().decode(CampaignState.self, from: JSONEncoder().encode(st))
        XCTAssertEqual(back, st)
    }

    /// Łatwo dla dzieci: na trasach z całej kampanii samo auto-prowadzenie (bez dotykania),
    /// autem o wymaganej mocy, kończy na podium wśród rywali o umiejętności z kampanii.
    func testAutopilotReachesPodiumAcrossCampaign() {
        for id in [1, 10, 20, 30, 40] {
            let spec = TrackCatalog.track(id: id)
            // Auto gracza: startowe z najmniejszymi ulepszeniami dającymi wymaganą moc.
            let def = Campaign.upgraded(starter, levels: Campaign.minimalUpgrades(starter, toReach: Campaign.requiredRating(spec)))
            let track = spec.makeTrack()
            // Rywale jak w grze: dowolny wygląd, statystyki dopasowane do trasy.
            var entries = (0..<5).map { (i: Int) -> Entry in
                Entry(name: "AI \(i)", def: Campaign.rival(looking: CarCatalog.builtIn[i % 3], on: spec), color: "#FFFFFF", isPlayer: false,
                      controller: AIController(skill: Campaign.aiSkill(spec), rng: SeededRandom(seed: UInt64(i) * 31 + UInt64(id))))
            }
            entries.append(Entry(name: "Gracz", def: def, color: "#FFFFFF", isPlayer: true,
                                 controller: AutoSteerController(input: FakeInput())))
            let sim = RaceSim(track: track, entries: entries, laps: spec.laps)
            while !(sim.player!.finished) && sim.time < 300 { sim.advance(); sim.events.removeAll() }
            let place = sim.finishOrder.firstIndex { $0 === sim.player! }.map { $0 + 1 } ?? 99
            print("trasa \(id) (\(spec.name)): auto-prowadzenie na miejscu \(place), moc \(Campaign.rating(def))/\(Campaign.requiredRating(spec))")
            XCTAssertLessThanOrEqual(place, 3, "trasa \(id)")
        }
    }
}

final class RivalTests: XCTestCase {
    /// Rywal z mocnym wyglądem nie jest mocniejszy, niż wymaga trasa.
    func testRivalStatsMatchTrackNotLooks() {
        var strong = CarCatalog.builtIn[1]
        strong.topSpeed = 120
        let spec = TrackCatalog.track(id: 5)
        let r = Campaign.rival(looking: strong, on: spec)
        XCTAssertEqual(r.id, strong.id)
        let starter = Campaign.rating(CarCatalog.car(id: Campaign.starterCar))
        XCTAssertLessThanOrEqual(Campaign.rating(r), max(starter, Campaign.requiredRating(spec)))
        // Na najtrudniejszej trasie rywal jest słabszy od wymaganej mocy, ale nie dużo.
        let last = TrackCatalog.all.last!
        let hard = Campaign.rating(Campaign.rival(looking: strong, on: last))
        XCTAssertLessThan(hard, Campaign.requiredRating(last))
        XCTAssertGreaterThan(hard, Campaign.requiredRating(last) - 60)
    }
}

final class KidSafetyTests: XCTestCase {
    private func pair(playerBehind: Bool, sideBySide: Bool = false) -> (player: Car, rival: Car, track: Double) {
        let len = 1000.0
        let def = CarCatalog.builtIn[0]
        let p = Car(name: "Gracz", def: def, color: "#FFFFFF", isPlayer: true, startDistance: 100, startLane: 0, trackLength: len)
        let r = Car(name: "Rywal", def: def, color: "#FFFFFF", isPlayer: false, startDistance: 100, startLane: 0, trackLength: len)
        if sideBySide {
            r.d = 1.5
            r.alphaVel = -0.5 // rywal wjeżdża bokiem w gracza
            r.speed = 60; p.speed = 60
        } else if playerBehind {
            p.s = 97; p.distance = 97; p.speed = 80; r.speed = 40
        } else {
            r.s = 97; r.distance = 97; r.speed = 80; p.speed = 40
        }
        return (p, r, len)
    }

    /// Rywal uderzający w tył gracza z dużą prędkością nie rozbija go.
    func testRivalCannotTakeDownPlayerFromBehind() {
        let (p, r, len) = pair(playerBehind: false)
        let out = Collisions.resolve([p, r], trackLength: len)
        XCTAssertFalse(p.wrecked)
        XCTAssertTrue(out.isEmpty)
    }

    /// Rywal wjeżdżający bokiem w gracza też go nie rozbija.
    func testRivalCannotTakeDownPlayerFromSide() {
        let (p, r, len) = pair(playerBehind: false, sideBySide: true)
        _ = Collisions.resolve([p, r], trackLength: len)
        XCTAssertFalse(p.wrecked)
    }

    /// Gracz nadal może rozbić rywala (takedown zostaje frajdą dla dziecka).
    func testPlayerCanStillTakeDownRival() {
        let (p, r, len) = pair(playerBehind: true)
        let out = Collisions.resolve([p, r], trackLength: len)
        XCTAssertTrue(r.wrecked)
        XCTAssertEqual(out.count, 1)
        XCTAssertFalse(p.wrecked)
    }

    /// Rozbite auto nie jest duchem: jadące obok odsuwa się od niego bokiem, nie tracąc prędkości.
    func testWreckedCarIsObstacleNotGhost() {
        let (p, r, len) = pair(playerBehind: true)
        r.wreck()
        p.s = r.s; p.distance = r.s; p.d = r.d + 0.5
        let speed = p.speed, d0 = p.d
        _ = Collisions.resolve([p, r], trackLength: len)
        XCTAssertGreaterThan(p.d, d0)
        XCTAssertEqual(p.speed, speed)
        XCTAssertFalse(p.wrecked)
    }

    /// Prostokąt kolizji ma wymiary aut z pary: długi „Grom” (4,7 m) i krótki „Zwinny” (4,0 m) stykają się
    /// przy odstępie środków (4,7 + 4,0) / 2 = 4,35 m, a nie przy stałych 4,4 m.
    func testCollisionUsesLengthsOfBothCars() {
        let len = 1000.0
        let long = CarCatalog.builtIn.first { $0.id == "grom" }!
        let short = CarCatalog.builtIn.first { $0.id == "zwinny" }!
        func rivals(gap: Double, _ a: CarDef, _ b: CarDef) -> (Car, Car) {
            let front = Car(name: "A", def: a, color: "#FFFFFF", isPlayer: false, startDistance: 100 + gap, startLane: 0, trackLength: len)
            let back = Car(name: "B", def: b, color: "#FFFFFF", isPlayer: false, startDistance: 100, startLane: 0, trackLength: len)
            front.speed = 40; back.speed = 41
            return (front, back)
        }
        // 4,38 m: przy stałym 4,4 m byłby styk, przy wymiarach tej pary — jeszcze nie.
        let (f1, b1) = rivals(gap: 4.38, long, short)
        _ = Collisions.resolve([f1, b1], trackLength: len)
        XCTAssertEqual(f1.s, 104.38, accuracy: 1e-9)
        XCTAssertEqual(b1.s, 100, accuracy: 1e-9)
        // 4,30 m: styk — auta rozsuwają się dokładnie na 4,35 m i tylko się przepychają (rywale się nie rozbijają).
        let (f2, b2) = rivals(gap: 4.30, long, short)
        _ = Collisions.resolve([f2, b2], trackLength: len)
        XCTAssertEqual(wrapDelta(f2.s, b2.s, len), 4.35, accuracy: 1e-9)
        XCTAssertFalse(f2.wrecked || b2.wrecked)
        // Dwa długie auta: styk już przy 4,6 m.
        let (f3, b3) = rivals(gap: 4.6, long, long)
        _ = Collisions.resolve([f3, b3], trackLength: len)
        XCTAssertEqual(wrapDelta(f3.s, b3.s, len), 4.7, accuracy: 1e-9)
        // Gracz w krótkim aucie wjeżdżany od tyłu przez długiego rywala: dalej tylko odepchnięcie.
        let p = Car(name: "Gracz", def: short, color: "#FFFFFF", isPlayer: true, startDistance: 104.3, startLane: 0, trackLength: len)
        let r = Car(name: "Rywal", def: long, color: "#FFFFFF", isPlayer: false, startDistance: 100, startLane: 0, trackLength: len)
        p.speed = 40; r.speed = 80
        let out = Collisions.resolve([p, r], trackLength: len)
        XCTAssertFalse(p.wrecked)
        XCTAssertTrue(out.isEmpty)
    }

    /// Rywal w fali uderzeniowej też nie rozbija gracza.
    func testRivalShockwaveCannotWreckPlayer() {
        let (p, r, len) = pair(playerBehind: false)
        r.speed = 41
        r.nitro.gauge = 1
        r.nitro.update(dt: 0.01, pressed: true)
        r.nitro.update(dt: 0.01, pressed: true) // podwójne = fala
        XCTAssertEqual(r.nitro.mode, .shockwave)
        _ = Collisions.resolve([p, r], trackLength: len)
        XCTAssertFalse(p.wrecked)
    }
}
