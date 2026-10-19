public struct Entry {
    public var name: String
    public var def: CarDef
    public var color: String
    public var isPlayer: Bool
    public var controller: Controller

    public init(name: String, def: CarDef, color: String, isPlayer: Bool, controller: Controller) {
        self.name = name
        self.def = def
        self.color = color
        self.isPlayer = isPlayer
        self.controller = controller
    }
}

public enum SimEvent {
    case takedown(attacker: Car, victim: Car)
    case wreck(Car)
    case nitro(Car, NitroMode)
    case nearMiss(Car)
    case pickup(Car)
    case driftBoost(Car)
    /// Uderzenie w bandę bez rozbicia; `intensity` — prędkość wbicia (m/s).
    case wallHit(Car, intensity: Double)
    case finish(Car, position: Int)
}

/// Cała logika wyścigu bez grafiki — da się ją puścić w testach.
public final class RaceSim {
    public static let step = 1.0 / 120

    public let track: Track
    public let laps: Int
    public let cars: [Car]
    public var events: [SimEvent] = []
    public private(set) var finishOrder: [Car] = []
    public private(set) var time = 0.0
    public private(set) var pickups: [NitroPickup]
    private var controllers: [ObjectIdentifier: Controller] = [:]
    /// Dla mijania „na włos”: znak różnicy pozycji gracz–rywal w poprzednim kroku.
    private var prevSide: [ObjectIdentifier: Double] = [:]

    public init(track: Track, entries: [Entry], laps: Int = RaceConfig.laps) {
        self.track = track
        self.laps = laps
        pickups = Pickups.layout(track: track)
        var cars: [Car] = []
        for (i, e) in entries.enumerated() {
            let row = Double(i / 2)
            let lane = (i % 2 == 0 ? 1.0 : -1.0) * track.halfWidth * 0.4
            let car = Car(name: e.name, def: e.def, color: e.color, isPlayer: e.isPlayer,
                          startDistance: -(row + 1) * RaceConfig.gridSpacing, startLane: lane,
                          trackLength: track.length)
            controllers[ObjectIdentifier(car)] = e.controller
            cars.append(car)
        }
        self.cars = cars
    }

    public var player: Car? { cars.first { $0.isPlayer } }

    public func setController(_ controller: Controller, for car: Car) {
        controllers[ObjectIdentifier(car)] = controller
    }

    public var raceDistance: Double { Double(laps) * track.length }

    public func lap(of car: Car) -> Int {
        min(laps, max(1, Int((car.distance / track.length).rounded(.down)) + 1))
    }

    public func standings() -> [Car] {
        cars.sorted { a, b in
            if a.finished != b.finished { return a.finished }
            if a.finished { return a.finishTime < b.finishTime }
            return a.distance > b.distance
        }
    }

    public func position(of car: Car) -> Int {
        (standings().firstIndex { $0 === car } ?? 0) + 1
    }

    /// Jeden krok fizyki o stałej długości `RaceSim.step`.
    public func advance() {
        let dt = RaceSim.step
        time += dt
        let player = self.player
        let ctx = RaceContext(track: track, playerDistance: player?.distance ?? 0)

        updateSlipstream()
        for car in cars {
            let input = controllers[ObjectIdentifier(car)]!.read(car: car, dt: dt, ctx: ctx)
            if !car.isPlayer { car.nitro.add(Physics.aiPassiveNitro * dt) }
            car.step(dt: dt, input: input, track: track)
            for e in car.events {
                switch e {
                case .wreck: events.append(.wreck(car))
                case .nitro(let mode): events.append(.nitro(car, mode))
                case .driftBoost: events.append(.driftBoost(car))
                case .wallHit(let v): events.append(.wallHit(car, intensity: v))
                }
            }
            car.events.removeAll()
        }

        for t in Collisions.resolve(cars, trackLength: track.length) {
            events.append(.takedown(attacker: t.attacker, victim: t.victim))
        }

        if let player { checkNearMiss(player) }
        collectPickups(dt: dt)

        for car in cars where !car.finished && car.distance >= raceDistance {
            car.finished = true
            car.finishTime = time
            finishOrder.append(car)
            events.append(.finish(car, position: finishOrder.count))
        }
    }

    /// Slipstream: auto tuż za rywalem, w tym samym pasie, jedzie szybciej i ładuje nitro.
    private func updateSlipstream() {
        for car in cars {
            car.slipstream = !car.wrecked && cars.contains { other in
                guard other !== car, !other.wrecked else { return false }
                let gap = wrapDelta(other.s, car.s, track.length)
                return gap > Physics.slipstreamMin && gap < Physics.slipstreamMax
                    && abs(other.d - car.d) < Physics.slipstreamWidth
            }
        }
    }

    private func collectPickups(dt: Double) {
        for i in pickups.indices {
            if !pickups[i].isActive {
                pickups[i].respawnIn -= dt
                continue
            }
            let p = pickups[i]
            for car in cars where !car.wrecked && !car.finished {
                if abs(wrapDelta(car.s, p.s, track.length)) < Physics.carLength / 2 + 0.5
                    && abs(car.d - p.d) < Physics.carWidth / 2 + 0.6 {
                    car.nitro.add(Physics.pickupNitro)
                    pickups[i].respawnIn = Physics.pickupRespawn
                    events.append(.pickup(car))
                    break
                }
            }
        }
    }

    private func checkNearMiss(_ player: Car) {
        for other in cars where other !== player {
            let ds = wrapDelta(player.s, other.s, track.length)
            let side: Double = ds > 0 ? 1 : (ds < 0 ? -1 : 0)
            let prev = prevSide[ObjectIdentifier(other)]
            prevSide[ObjectIdentifier(other)] = side
            guard prev == -1, side == 1, !player.wrecked, !other.wrecked else { continue }
            let gap = abs(player.d - other.d)
            if gap > Physics.carWidth && gap < Physics.carWidth + Physics.nearMissGap {
                player.nitro.add(Physics.nearMissNitro)
                events.append(.nearMiss(player))
            }
        }
    }
}
