import Foundation

public struct CarInput {
    /// −1…1, dodatnie = w lewo.
    public var steer: Double
    /// Drift przy prędkości (kierunek ze skrętu albo z najbliższego zakrętu). Nigdy nie hamuje —
    /// przy małej prędkości czeka, aż auto się rozpędzi.
    public var drift: Bool
    /// Wciśnięcie nitro w tym kroku (zbocze, nie stan przycisku).
    public var nitro: Bool
    /// Hamowanie przed zbyt ciasnym zakrętem (używa go kierownica komputera).
    public var brake: Bool

    public init(steer: Double = 0, drift: Bool = false, nitro: Bool = false, brake: Bool = false) {
        self.steer = steer
        self.drift = drift
        self.nitro = nitro
        self.brake = brake
    }
}

public enum CarEvent {
    case wreck
    case nitro(NitroMode)
    /// Zryw po zakończonym drifcie (mini-turbo).
    case driftBoost
}

/// Arkadowy model jazdy we współrzędnych trasy. `alphaVel` to kąt toru jazdy względem osi trasy,
/// `slide` — o ile przód auta jest obrócony względem toru jazdy (drift). Auto przyspiesza samo;
/// gracz skręca, driftuje i odpala nitro.
public final class Car {
    public let name: String
    public let def: CarDef
    /// Kolor lakieru jako hex.
    public let color: String
    public let isPlayer: Bool

    public var s: Double
    public var d: Double
    /// Przejechany dystans od startu (bez zawijania) — z niego okrążenia i kolejność.
    public var distance: Double
    public var alphaVel = 0.0
    public var slide = 0.0
    public var speed = 0.0
    public private(set) var drifting = false
    /// Strona poślizgu: +1 w lewo, −1 w prawo.
    public private(set) var driftDir = 0.0
    public var wreckTimer = 0.0
    public var finished = false
    public var finishTime = 0.0
    public var takedowns = 0
    /// Mnożnik prędkości maksymalnej — poziom trudności i „gumka” rywali.
    public var speedScale = 1.0
    /// Ile sekund trwa już bieżący drift (ładowanie mini-turbo).
    public private(set) var driftCharge = 0.0
    /// Ile jeszcze drift trwa niezależnie od przycisku (krótkie stuknięcie daje pełny poślizg).
    private var driftHold = 0.0
    /// Pozostały czas zrywu po drifcie.
    public private(set) var driftBoostTimer = 0.0
    /// Ustawiane przez RaceSim: auto jedzie w cieniu aerodynamicznym rywala.
    public var slipstream = false
    public let nitro = Nitro()
    public var events: [CarEvent] = []

    public init(name: String, def: CarDef, color: String, isPlayer: Bool,
                startDistance: Double, startLane: Double, trackLength: Double) {
        self.name = name
        self.def = def
        self.color = color
        self.isPlayer = isPlayer
        distance = startDistance
        s = wrap(startDistance, trackLength)
        d = startLane
    }

    public var wrecked: Bool { wreckTimer > 0 }

    /// Kąt przodu auta względem osi trasy (do rysowania).
    public var alphaFace: Double { alphaVel + slide }

    public var boost: Double { 1 + (nitro.boost - 1) * def.nitroPower }

    public var lateralSpeed: Double { speed * sin(alphaVel) }

    public func wreck() {
        guard !wrecked else { return }
        wreckTimer = Physics.wreckTime
        drifting = false
        driftCharge = 0
        driftBoostTimer = 0
        nitro.cancel()
        events.append(.wreck)
    }

    public func step(dt: Double, input: CarInput, track: Track) {
        if wrecked {
            stepWrecked(dt: dt, track: track)
            return
        }

        if let started = nitro.update(dt: dt, pressed: input.nitro) {
            events.append(.nitro(started))
            speed += Physics.nitroKick * (started == .shockwave ? 2 : started == .perfect ? 1.4 : 1)
        }

        let steer = clamp(input.steer, -1, 1)
        if !drifting && input.drift && speed > Physics.driftMinSpeed {
            // Kolejność przycisków nie ma znaczenia: DRIFT bez skrętu też wchodzi w poślizg.
            drifting = true
            driftHold = Physics.driftMinTime
            driftDir = abs(steer) > 0.25 ? (steer > 0 ? 1 : -1) : preferredDriftDir(track: track)
        } else if drifting && ((!input.drift && driftHold <= 0) || speed < Physics.driftMinSpeed * 0.7) {
            drifting = false
            // Mini-turbo: im dłuższy poślizg, tym dłuższy zryw.
            if driftCharge >= Physics.driftBoostMinCharge && speed >= Physics.driftMinSpeed {
                driftBoostTimer = min(Physics.driftBoostMaxTime, driftCharge * 0.6)
                speed += Physics.driftBoostKick
                events.append(.driftBoost)
            }
            driftCharge = 0
        } else if drifting && abs(steer) > Physics.driftSwitchSteer && (steer > 0 ? 1.0 : -1.0) != driftDir {
            // Wyraźny skręt w drugą stronę przekłada poślizg (lekki — tylko kontruje).
            driftDir = -driftDir
        }
        driftHold = max(0, driftHold - dt)
        // DRIFT nie hamuje (dzieci trzymają go od startu); hamuje tylko kierownica komputera przed zakrętem.
        let braking = input.brake

        if drifting { driftCharge += dt * min(1, abs(slide) / Physics.driftSlideAngle) }
        driftBoostTimer = max(0, driftBoostTimer - dt)

        let boost = self.boost
        // Dodatki się nie mnożą: liczy się najmocniejszy z nitro, zrywu po drifcie i slipstreamu.
        let extra = max(boost, driftBoostTimer > 0 ? Physics.driftBoostSpeed : 1, slipstream ? Physics.slipstreamSpeed : 1)
        let top = def.topSpeed * speedScale * extra * (drifting ? Physics.driftSpeedFactor : 1)
        if braking {
            speed = max(0, speed - Physics.brakeDecel * dt)
        } else if speed < top {
            let accel = def.accel * (boost > 1 || driftBoostTimer > 0 ? Physics.nitroAccelFactor : 1)
            * (slipstream ? Physics.slipstreamAccel : 1)
            speed = min(top, speed + accel * dt * (1 - 0.6 * speed / top))
        } else {
            speed = damp(speed, top, rate: Physics.overspeedDecay, dt: dt)
        }

        let speedFactor = clamp(speed / 15, 0, 1)
        // W poślizgu auto samo skręca w stronę driftu; skręt w przeciwną stronę je kontruje.
        let effectiveSteer = drifting ? clamp(steer + driftDir * Physics.driftAutoSteer, -1, 1) : steer
        let yaw = effectiveSteer * yawRatePerSteer
        alphaVel += yaw * dt
        let targetSlide = drifting ? driftDir * Physics.driftSlideAngle : 0
        slide = damp(slide, targetSlide, rate: drifting ? 6 : 8, dt: dt)

        if abs(steer) < 0.1 && !drifting {
            alphaVel = damp(alphaVel, 0, rate: Physics.steerAssist, dt: dt)
        }

        advance(dt: dt, track: track)
        collideWalls(track: track)

        if drifting { nitro.add(Physics.driftNitroGain * speedFactor * dt) }
        if slipstream { nitro.add(Physics.slipstreamNitro * dt) }
    }

    /// Szybkość obrotu (rad/s) przy pełnym skręcie w obecnym stanie auta: rośnie od postoju,
    /// słabnie przy dużej prędkości (stabilność), w drifcie mocniejsza.
    public var yawRatePerSteer: Double {
        let speedFactor = clamp(speed / 15, 0, 1)
        let falloff = 1 - Physics.steerFalloff * clamp(speed / Physics.steerFalloffSpeed, 0, 1)
        return def.handling * speedFactor * falloff * (drifting ? Physics.driftSteerFactor : 1)
    }

    /// Kierunek zakrętu 20–80 m przed autem; na prostej — strona, w którą auto już jedzie.
    private func preferredDriftDir(track: Track) -> Double {
        var sum = 0.0
        var k = 20.0
        while k <= 80 { sum += track.sample(at: s + k).curvature; k += 5 }
        if abs(sum) > 0.01 { return sum > 0 ? 1 : -1 }
        return alphaVel >= 0 ? 1 : -1
    }

    private func stepWrecked(dt: Double, track: Track) {
        wreckTimer -= dt
        speed = damp(speed, 0, rate: 3, dt: dt)
        advance(dt: dt, track: track)
        let limit = track.halfWidth - Physics.carWidth / 2
        d = clamp(d, -limit, limit)
        if wreckTimer <= 0 {
            wreckTimer = 0
            alphaVel = 0
            slide = 0
            speed = def.topSpeed * 0.5
        }
    }

    /// Ruch wzdłuż trasy. Zakręt trasy obraca kąt auta względem jej osi.
    private func advance(dt: Double, track: Track) {
        let sm = track.sample(at: s)
        // Po wewnętrznej stronie zakrętu oś trasy przesuwa się szybciej niż auto.
        let denom = max(0.3, 1 - sm.curvature * d)
        let ds = speed * cos(alphaVel) * dt / denom
        alphaVel -= sm.curvature * ds
        alphaVel = clamp(alphaVel, -Physics.maxAlpha, Physics.maxAlpha)
        d += speed * sin(alphaVel) * dt
        s = wrap(s + ds, track.length)
        distance += ds
    }

    private func collideWalls(track: Track) {
        let limit = track.halfWidth - Physics.carWidth / 2
        guard abs(d) > limit else { return }
        let side: Double = d > 0 ? 1 : -1
        d = side * limit
        let into = sin(alphaVel) * side
        guard into > 0 else { return }
        if speed * into > Physics.wreckImpact {
            wreck()
        } else {
            // Muśnięcie prawie nic nie kosztuje, uderzenie pod kątem — wyraźnie; auto odbija się od bandy.
            speed *= 1 - Physics.wallFriction * into * into * 2
            alphaVel = -alphaVel * 0.25
        }
    }
}
