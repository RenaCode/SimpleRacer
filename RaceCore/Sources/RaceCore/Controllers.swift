public struct RaceContext {
    public let track: Track
    public let playerDistance: Double
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

/// Rywal: trzyma się wybranego pasa, z wyprzedzeniem kontruje zakręty, driftuje w ciasnych,
/// odpala nitro na prostych i trafia w perfect nitro zależnie od umiejętności.
public final class AIController: Controller {
    private let skill: Double
    private let rng: SeededRandom
    private var lane = 0.0
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

        let near = track.sample(at: car.s + clamp(car.speed * 0.25, 4, 20))
        let far = track.sample(at: car.s + clamp(car.speed * 0.9, 15, 70))
        let handling = car.def.handling * (car.drifting ? Physics.driftSteerFactor : 1)
        let curveSteer = near.curvature * car.speed / handling
        let desiredAlpha = clamp((lane - car.d) * 0.04, -0.25, 0.25)
        let steer = clamp(curveSteer + (desiredAlpha - car.alphaVel) * 2.5, -1, 1)

        let neededYaw = abs(far.curvature * car.speed)
        let drift = neededYaw > car.def.handling * 0.9 && abs(steer) > 0.25

        var nitro = false
        let straight = abs(far.curvature) < 0.004
        if car.nitro.mode == .off && car.nitro.gauge > 0.4 && straight && rng.next() < dt * 1.5 { nitro = true }
        if car.nitro.inPerfectWindow && rng.next() < skill * dt * 6 { nitro = true }

        // Gumka: dystans do gracza lekko zmienia prędkość, żeby wyścig był wyrównany.
        let gap = ctx.playerDistance - car.distance
        car.speedScale = skill * clamp(1 + gap / 800, 0.93, 1.07)

        return CarInput(steer: steer, drift: drift, nitro: nitro)
    }
}
