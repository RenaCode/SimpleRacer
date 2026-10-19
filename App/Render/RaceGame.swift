import Foundation
import Observation
import RaceCore
import RealityKit
import UIKit

struct HudState {
    var speedKmh = 0.0
    var position = 1
    var total = 1
    var lap = 1
    var laps = 1
    var time = 0.0
    var gauge = 0.0
    var mode: NitroMode = .off
    var perfectWindow = false
    /// Ułamek pozostałego spalania nitro (0…1).
    var burn = 0.0
}

struct Toast: Identifiable, Equatable {
    enum Kind { case good, bad, info }
    let id = UUID()
    let text: String
    let kind: Kind
}

/// Wyścig z grafiką: opakowuje RaceSim, ustawia encje aut, prowadzi kamerę i wystawia stan HUD dla SwiftUI.
@MainActor
@Observable
final class RaceGame {
    enum Phase { case countdown, racing, finished }

    private(set) var phase: Phase = .countdown
    private(set) var countdownText: String?
    private(set) var hud = HudState()
    private(set) var toasts: [Toast] = []
    private(set) var result: RaceResult?
    /// Pauza: stoi fizyka i odliczanie, scena dalej się rysuje.
    var paused = false

    @ObservationIgnored let input = GameInput()
    @ObservationIgnored let root = Entity()
    @ObservationIgnored var subscription: EventSubscription?
    @ObservationIgnored private let camera = PerspectiveCamera()
    @ObservationIgnored private let sim: RaceSim
    @ObservationIgnored private var cars: [(Car, CarEntity)] = []
    @ObservationIgnored private var pickupEntities: [Entity] = []
    @ObservationIgnored private var clock = 0.0
    @ObservationIgnored private var countdown = RaceConfig.countdown
    @ObservationIgnored private var finishTimer = 0.0
    @ObservationIgnored private var acc = 0.0
    @ObservationIgnored private var camHeading = 0.0
    @ObservationIgnored private var fov = 70.0
    @ObservationIgnored private var shake = 0.0
    @ObservationIgnored private var hudTimer = 0.0
    @ObservationIgnored private var pendingResult: RaceResult?

    private static let rivals = ["Kuba", "Ola", "Marek", "Zosia", "Bartek", "Ewa", "Tomek"]

    @ObservationIgnored let spec: TrackSpec

    init(profile: Profile, spec: TrackSpec, playerCar: CarDef) {
        self.spec = spec
        debugLog("wyścig: start budowania (trasa \(spec.id))")
        defer { debugLog("wyścig: scena gotowa") }
        let rng = SeededRandom(seed: UInt64(Date().timeIntervalSince1970 * 1000))
        let track = spec.makeTrack()
        let names = Self.rivals.shuffled()
        // Rywale: dowolny wygląd, statystyki dopasowane do trasy (lekko słabsze od wymaganych).
        var entries: [Entry] = (0..<RaceConfig.opponents).map { i in
            Entry(name: names[i], def: Campaign.rival(looking: rng.pick(LocalAssets.shared.loadedCars), on: spec),
                  color: rng.pick(CarCatalog.colors), isPlayer: false,
                  controller: AIController(skill: Campaign.aiSkill(spec) + rng.next() * 0.04,
                                           rng: SeededRandom(seed: UInt64(rng.next() * 1e15))))
        }
        // Gracz startuje z końca stawki i musi przebić się do przodu.
        let playerControl: Controller = profile.autoSteer ? AutoSteerController(input: input) : PlayerController(input: input)
        entries.append(Entry(name: "Ty", def: playerCar, color: profile.colorHex,
                             isPlayer: true, controller: playerControl))
        sim = RaceSim(track: track, entries: entries, laps: spec.laps)
        countdownText = String(Int(RaceConfig.countdown))

        do {
            root.addChild(try TrackBuilder.build(track, theme: .of(spec.region)))
            debugLog("wyścig: trasa zbudowana")
        } catch {
            assertionFailure("Nie udało się zbudować trasy: \(error)")
        }
        debugLog("wyścig: auta…")
        for car in sim.cars {
            let e = CarEntity(def: car.def, color: UIColorHex.color(car.color))
            root.addChild(e.root)
            cars.append((car, e))
        }

        let sun = DirectionalLight()
        sun.light.intensity = 3500
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 60, depthBias: 2)
        sun.look(at: .zero, from: [80, 140, 40], relativeTo: nil)
        root.addChild(sun)

        root.addChild(SkyEnvironment.skyDome(radius: 2000))
        let pickupModel = Self.pickupModel()
        for p in sim.pickups {
            let e = pickupModel.clone(recursive: true)
            let w = track.toWorld(s: p.s, d: p.d)
            e.position = [Float(w.x), 0.9, Float(w.z)]
            root.addChild(e)
            pickupEntities.append(e)
        }

        camera.camera.near = 0.5
        camera.camera.far = 2500
        camera.camera.fieldOfViewInDegrees = Float(fov)
        root.addChild(camera)

        SkyEnvironment.applyLighting(to: root)
        #if DEBUG || FAMILY
        // Do zrzutów ekranu wyników: `-finishSoon` stawia gracza 150 m przed metą.
        if ProcessInfo.processInfo.arguments.contains("-finishSoon") {
            player.distance = sim.raceDistance - 150
            player.s = wrap(player.distance, track.length)
        }
        #endif
        camHeading = track.sample(at: player.s).heading
        updateEntities()
        updateCamera(dt: 1)
    }

    private var player: Car { sim.player! }

    /// Butla nitro: błyszcząca niebieska kapsuła z białym pasem i zaworem, w świetlistej poświacie,
    /// otoczona wirującym pierścieniem.
    private static func pickupModel() -> Entity {
        let e = Entity()
        let blue = UIColor(red: 0.15, green: 0.6, blue: 1, alpha: 1)
        var shell = PhysicallyBasedMaterial()
        shell.baseColor = .init(tint: blue)
        shell.emissiveColor = .init(color: blue)
        shell.emissiveIntensity = 1.6
        shell.metallic = 0.6
        shell.roughness = 0.2
        shell.clearcoat = 1.0
        // Kapsuła: walec z półkulami.
        let tank = ModelEntity(mesh: .generateCylinder(height: 0.7, radius: 0.3), materials: [shell])
        e.addChild(tank)
        for y: Float in [-0.35, 0.35] {
            let cap = ModelEntity(mesh: .generateSphere(radius: 0.3), materials: [shell])
            cap.position.y = y
            e.addChild(cap)
        }
        let band = ModelEntity(mesh: .generateCylinder(height: 0.14, radius: 0.31),
                               materials: [Materials.glow(.white, intensity: 1.2)])
        e.addChild(band)
        let valve = ModelEntity(mesh: .generateCylinder(height: 0.16, radius: 0.1), materials: [Materials.chrome])
        valve.position.y = 0.72
        e.addChild(valve)
        // Poświata i pierścień (półprzezroczyste, nieoświetlane — świecą same).
        var haloMat = UnlitMaterial(color: UIColor(red: 0.4, green: 0.8, blue: 1, alpha: 1))
        haloMat.blending = .transparent(opacity: .init(floatLiteral: 0.18))
        let halo = ModelEntity(mesh: .generateSphere(radius: 0.75), materials: [haloMat])
        e.addChild(halo)
        var ringMat = UnlitMaterial(color: UIColor(red: 0.55, green: 0.9, blue: 1, alpha: 1))
        ringMat.blending = .transparent(opacity: .init(floatLiteral: 0.7))
        let ring = ModelEntity(mesh: .generateCylinder(height: 0.03, radius: 0.62), materials: [ringMat])
        ring.orientation = simd_quatf(angle: .pi / 7, axis: [1, 0, 0])
        e.addChild(ring)
        return e
    }

    func update(dt rawDt: Double) {
        let dt = min(rawDt, 0.05)
        input.poll()
        if paused {
            _ = input.consumeNitro() // wciśnięcia z czasu pauzy nie odpalają nitro po wznowieniu
            AudioManager.shared.setEngine(speed: 0, nitro: false, running: false)
            return
        }
        let p = player
        AudioManager.shared.setEngine(speed: p.speed / p.def.topSpeed, nitro: p.nitro.mode != .off, running: !p.wrecked)
        clock += dt

        switch phase {
        case .countdown:
            countdown -= dt
            if countdown > 0 {
                let text = String(Int(countdown.rounded(.up)))
                if text != countdownText {
                    countdownText = text
                    AudioManager.shared.play(.beep)
                }
            } else {
                countdownText = nil
                phase = .racing
                toast("START!", .good)
                AudioManager.shared.play(.go)
            }
        case .racing, .finished:
            acc += dt
            while acc >= RaceSim.step {
                sim.advance()
                acc -= RaceSim.step
            }
            handleEvents()
            if phase == .finished {
                finishTimer -= dt
                if finishTimer <= 0, let r = pendingResult {
                    result = r
                    pendingResult = nil
                }
            }
        }

        updateEntities()
        updateCamera(dt: dt)
        hudTimer -= dt
        if hudTimer <= 0 {
            hudTimer = 1.0 / 20
            updateHud()
        }
    }

    private func handleEvents() {
        let p = player
        let events = sim.events
        sim.events.removeAll()
        for e in events {
            switch e {
            case let .takedown(attacker, victim):
                if attacker === p {
                    toast("TAKEDOWN!", .good)
                    AudioManager.shared.play(.takedown)
                    shake = 0.5
                } else if victim === p {
                    toast("ROZBITY!", .bad)
                }
            case let .wreck(car) where car === p:
                shake = 0.8
                AudioManager.shared.play(.crash)
                let byRival = events.contains { if case let .takedown(_, v) = $0 { return v === p }; return false }
                if !byRival { toast("ROZBITY!", .bad) }
            case let .nitro(car, mode) where car === p:
                AudioManager.shared.play(.nitro)
                if mode == .perfect { toast("PERFECT NITRO", .good) }
                if mode == .shockwave {
                    toast("FALA UDERZENIOWA", .good)
                    shake = 0.4
                }
            case .nearMiss:
                toast("NA WŁOS! +nitro", .info)
            case let .driftBoost(car) where car === p:
                toast("MINI-TURBO!", .good)
                AudioManager.shared.play(.nitro)
            case let .pickup(car) where car === p:
                toast("+NITRO", .info)
                AudioManager.shared.play(.pickup)
            case let .finish(car, position) where car === p:
                phase = .finished
                finishTimer = RaceConfig.finishDelay
                toast("META — \(position). miejsce", .good)
                // Po mecie autem gracza jedzie AI, a kamera zostaje.
                sim.setController(AIController(skill: 0.9, rng: SeededRandom(seed: 1)), for: p)
                pendingResult = RaceResult(position: position, total: sim.cars.count, time: p.finishTime,
                                           takedowns: p.takedowns, carName: p.def.name, trackId: spec.id)
            default:
                break
            }
        }
    }

    private func updateEntities() {
        for (car, e) in cars {
            let w = sim.track.toWorld(s: car.s, d: car.d)
            e.root.position = [Float(w.x), 0, Float(w.z)]
            e.root.orientation = simd_quatf(angle: Float(w.heading + car.alphaFace), axis: [0, 1, 0])
            if car.wrecked {
                let t = Float(1 - car.wreckTimer / Physics.wreckTime)
                e.body.orientation = simd_quatf(angle: t * .pi * 2, axis: [0, 1, 0])
                    * simd_quatf(angle: sin(t * .pi * 2) * 0.8, axis: [0, 0, 1])
                    * simd_quatf(angle: sin(t * .pi) * 0.6, axis: [1, 0, 0])
                e.body.position.y = sin(t * .pi) * 1.5
            } else {
                e.body.orientation = simd_quatf(angle: Float(-car.slide * 0.12), axis: [0, 0, 1])
                e.body.position.y = 0
            }
            e.setFlame(car.nitro.mode)
            e.setSmoke(car.drifting)
            e.spinWheels(distance: car.distance)
        }
        // Butle wirują i unoszą się; zebrane znikają do czasu odnowienia.
        let spin = simd_quatf(angle: Float(clock * 2), axis: [0, 1, 0])
        let bob = Float(sin(clock * 3)) * 0.12
        for (i, e) in pickupEntities.enumerated() {
            e.isEnabled = sim.pickups[i].isActive
            e.orientation = spin
            e.position.y = 0.9 + bob
        }
    }

    private func updateCamera(dt: Double) {
        let p = player
        let w = sim.track.toWorld(s: p.s, d: p.d)
        // Kamera podąża za torem jazdy, nie za przodem auta — w drifcie widać poślizg.
        camHeading = dampAngle(camHeading, w.heading + p.alphaVel, rate: 6, dt: dt)
        let fx = sin(camHeading), fz = cos(camHeading)
        let back = 6.2 + p.speed * 0.02
        shake = max(0, shake - dt)
        let sh = shake * 0.4 + (p.nitro.mode == .shockwave ? 0.08 : 0)
        let jitter = { sh > 0 ? Double.random(in: -0.5...0.5) * sh : 0 }
        let from = SIMD3<Float>(Float(w.x - fx * back + jitter()), Float(2.1 + jitter()), Float(w.z - fz * back))
        let at = SIMD3<Float>(Float(w.x + fx * 6), 1.15, Float(w.z + fz * 6))
        camera.look(at: at, from: from, relativeTo: nil)
        let target = 68 + clamp(p.speed / p.def.topSpeed, 0, 1.6) * 10 + (p.nitro.mode != .off ? 8 : 0)
        fov = damp(fov, target, rate: 4, dt: dt)
        camera.camera.fieldOfViewInDegrees = Float(fov)
    }

    private func updateHud() {
        let p = player
        let n = p.nitro
        let burnTotal = n.mode == .shockwave ? NitroConfig.shockwaveTime : NitroConfig.burnTime
        hud = HudState(
            speedKmh: p.speed * 3.6,
            position: p.finished ? (sim.finishOrder.firstIndex { $0 === p } ?? 0) + 1 : sim.position(of: p),
            total: sim.cars.count,
            lap: sim.lap(of: p),
            laps: sim.laps,
            time: p.finished ? p.finishTime : sim.time,
            gauge: n.gauge,
            mode: n.mode,
            perfectWindow: n.inPerfectWindow,
            burn: n.mode == .off ? 0 : clamp(n.burnLeft / burnTotal, 0, 1)
        )
    }

    private func toast(_ text: String, _ kind: Toast.Kind) {
        // Ten sam komunikat tuż po poprzednim (np. seria butli nitro) nie dubluje się na ekranie.
        if toasts.last?.text == text { return }
        let t = Toast(text: text, kind: kind)
        toasts.append(t)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            self?.toasts.removeAll { $0.id == t.id }
        }
    }
}
