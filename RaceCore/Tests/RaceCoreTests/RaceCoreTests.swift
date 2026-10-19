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
        let entries = (0..<6).map { i in
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

    /// Przy małej prędkości ten sam przycisk hamuje.
    func testDriftButtonBrakesWhenSlow() {
        let c = car(at: 50, speed: 10)
        drive(c, seconds: 0.3, input: CarInput(steer: 0, drift: true))
        XCTAssertFalse(c.drifting)
        XCTAssertLessThan(c.speed, 10)
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
