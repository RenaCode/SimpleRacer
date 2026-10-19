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
