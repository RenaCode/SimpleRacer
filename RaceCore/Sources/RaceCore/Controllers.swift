public struct RaceContext {
    public let track: Track
    public let playerDistance: Double
    /// Wszystkie auta wyścigu (z tym, które steruje) — do omijania wraków.
    public var cars: [Car] = []
}

public protocol Controller: AnyObject {
    func read(car: Car, dt: Double, ctx: RaceContext) -> CarInput
}

/// Źródło sterowania gracza — dotyk, klawiatura albo pad (patrz App/Input).
public protocol PlayerInputSource: AnyObject {
    var steer: Double { get }
    var drift: Bool { get }
    /// Zwraca true raz na każde wciśnięcie nitro.
    func consumeNitro() -> Bool
}

public final class PlayerController: Controller {
    private let input: PlayerInputSource

    public init(input: PlayerInputSource) { self.input = input }

    public func read(car: Car, dt: Double, ctx: RaceContext) -> CarInput {
        CarInput(steer: input.steer, drift: input.drift, nitro: input.consumeNitro())
    }
}

/// Wspólna „kierownica” rywali i auto-prowadzenia: trzyma pas i z wyprzedzeniem wchodzi w zakręty.
public enum LineFollower {
    /// Skręt potrzebny, żeby jechać pasem `lane` (przesunięcie w bok, m). `gain` — jak ostro zjeżdżać
    /// na pas (kąt na metr odchyłki); większy przy omijaniu wraku.
    public static func steer(car: Car, track: Track, lane: Double, gain: Double = 0.04) -> Double {
        let near = track.sample(at: car.s + clamp(car.speed * 0.25, 4, 20))
        let curveSteer = near.curvature * car.speed / max(0.1, car.yawRatePerSteer)
        let desiredAlpha = clamp((lane - car.d) * gain, -0.25, 0.25)
        return clamp(curveSteer + (desiredAlpha - car.alphaVel) * 2.5, -1, 1)
    }

    /// Pas, który omija rozbite auta przed `car`: gdy wrak stoi na drodze do `lane` (bliżej niż styk boków
    /// plus zapas), cel przesuwa się obok wraku. Strona: ta, po której auto już jest; gdy jedzie prosto
    /// na wrak — ta z większym miejscem do bandy. Bez tego jadący z tyłu przenikał przez wrak w ok. 0,2 s
    /// (odpychanie w `Collisions` to tylko ułamek metra na krok).
    public static func avoidingWrecks(car: Car, lane: Double, ctx: RaceContext) -> Double {
        let track = ctx.track
        var lane = lane
        let lookahead = max(Physics.wreckLookahead, car.speed)
        for other in ctx.cars where other !== car && other.wrecked {
            let ahead = wrapDelta(other.s, car.s, track.length)
            // Także gdy auto jest już obok wraku — inaczej wracałoby na pas w połowie mijania.
            guard ahead > -(car.def.shape.length + other.def.shape.length) / 2, ahead < lookahead else { continue }
            let clearance = (car.def.shape.width + other.def.shape.width) / 2 + Physics.wreckAvoidMargin
            guard abs(lane - other.d) < clearance else { continue }
            let edge = track.halfWidth - car.def.shape.width / 2
            let left = other.d + clearance, right = other.d - clearance
            let fitsLeft = left <= edge, fitsRight = right >= -edge
            let side = car.d - other.d
            let goLeft: Bool
            if abs(side) > 0.5 && (side > 0 ? fitsLeft : fitsRight) {
                goLeft = side > 0
            } else {
                goLeft = edge - left >= right + edge
            }
            lane = goLeft ? min(left, edge) : max(right, -edge)
        }
        return lane
    }

    /// Czy przed autem jest zakręt ciaśniejszy, niż auto zdoła pokonać nawet w drifcie przy obecnej prędkości.
    public static func needsBrake(car: Car, track: Track) -> Bool {
        // Pętla zamiast `map` — bez tablicy na każdy krok fizyki (120 Hz × 6 aut).
        var maxK = 0.0
        for ahead in stride(from: 10.0, through: max(20, car.speed * 1.6), by: 8) {
            maxK = max(maxK, abs(track.sample(at: car.s + ahead).curvature))
        }
        let capacity = car.yawRatePerSteer / (car.drifting ? 1 : 1 / Physics.driftSteerFactor) * 0.85
        return maxK * car.speed > capacity
    }

    /// Czy zakręt przed autem jest za ciasny na zwykły skręt (trzeba driftować).
    public static func needsDrift(car: Car, track: Track, steer: Double) -> Bool {
        let far = track.sample(at: car.s + clamp(car.speed * 0.9, 15, 110))
        let normalYaw = car.yawRatePerSteer / (car.drifting ? Physics.driftSteerFactor : 1)
        return abs(far.curvature * car.speed) > normalYaw * 0.9 && abs(steer) > 0.25
    }
}

/// Auto-prowadzenie gracza: auto samo trzyma pas i pokonuje zakręty (także driftem),
/// a ◀ ▶ przestawiają je o jeden pas. DRIFT i NITRO działają jak przy ręcznym sterowaniu.
public final class AutoSteerController: Controller {
    private let input: PlayerInputSource
    /// Pasy jako ułamek połowy szerokości trasy: prawy, środek, lewy.
    private static let lanes = [-0.55, 0.0, 0.55]
    private var laneIndex: Int?
    private var prevSteer = 0.0

    public init(input: PlayerInputSource) { self.input = input }

    public func read(car: Car, dt: Double, ctx: RaceContext) -> CarInput {
        let track = ctx.track
        if laneIndex == nil {
            let rel = car.d / track.halfWidth
            laneIndex = Self.lanes.indices.min { abs(Self.lanes[$0] - rel) < abs(Self.lanes[$1] - rel) }
        }
        // Zmiana pasa na wciśnięcie (zbocze), nie na przytrzymanie.
        let raw = input.steer
        if raw > 0.5 && prevSteer <= 0.5 { laneIndex = min(Self.lanes.count - 1, laneIndex! + 1) }
        if raw < -0.5 && prevSteer >= -0.5 { laneIndex = max(0, laneIndex! - 1) }
        prevSteer = raw

        let wanted = Self.lanes[laneIndex!] * track.halfWidth
        let lane = LineFollower.avoidingWrecks(car: car, lane: wanted, ctx: ctx)
        let steer = LineFollower.steer(car: car, track: track, lane: lane, gain: lane == wanted ? 0.04 : Physics.wreckAvoidGain)
        let drift = input.drift || LineFollower.needsDrift(car: car, track: track, steer: steer)
        return CarInput(steer: steer, drift: drift, nitro: input.consumeNitro(),
                        brake: LineFollower.needsBrake(car: car, track: track))
    }
}

/// Rywal: trzyma się wybranego pasa, z wyprzedzeniem kontruje zakręty, driftuje w ciasnych,
/// odpala nitro na prostych i trafia w perfect nitro zależnie od umiejętności.
public final class AIController: Controller {
    private let skill: Double
    private let rng: SeededRandom
    private(set) var lane = 0.0
    private var laneTimer = 0.0

    public init(skill: Double, rng: SeededRandom) {
        self.skill = skill
        self.rng = rng
    }

    public func read(car: Car, dt: Double, ctx: RaceContext) -> CarInput {
        let track = ctx.track
        laneTimer -= dt
        if laneTimer <= 0 {
            lane = (rng.next() * 2 - 1) * track.halfWidth * 0.55
            laneTimer = 3 + rng.next() * 4
        }

        let target = LineFollower.avoidingWrecks(car: car, lane: lane, ctx: ctx)
        let steer = LineFollower.steer(car: car, track: track, lane: target, gain: target == lane ? 0.04 : Physics.wreckAvoidGain)
        let drift = LineFollower.needsDrift(car: car, track: track, steer: steer)

        var nitro = false
        // Nitro tylko, gdy na całym odcinku spalania (ok. 200 m) nie ma ostrego zakrętu. Odcinek
        // sprawdzamy dopiero, gdy nitro w ogóle wchodzi w grę (20 próbek trasy na krok to drogo).
        func straightAhead() -> Bool {
            for ahead in stride(from: 10.0, through: 200, by: 10) where abs(track.sample(at: car.s + ahead).curvature) >= 0.004 {
                return false
            }
            return true
        }
        if car.nitro.mode == .off && car.nitro.gauge > 0.4 && straightAhead() && rng.next() < dt * 1.5 { nitro = true }
        if car.nitro.inPerfectWindow && rng.next() < skill * dt * 6 { nitro = true }

        // Gumka: dystans do gracza lekko zmienia prędkość, żeby wyścig był wyrównany.
        let gap = ctx.playerDistance - car.distance
        // Na korzyść gracza (gra dla dzieci): rywal daleko z przodu zwalnia mocniej, niż przyspiesza z tyłu.
        car.speedScale = skill * clamp(1 + gap / 600, 0.85, 1.05)

        return CarInput(steer: steer, drift: drift, nitro: nitro, brake: LineFollower.needsBrake(car: car, track: track))
    }
}
