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
    /// Gra czeka pod ekranem ładowania: scena się renderuje (rozgrzewka shaderów i efektów),
    /// ale odliczanie jeszcze nie biegnie. `release()` zdejmuje blokadę.
    @ObservationIgnored private(set) var holdStart = true
    /// Ile klatek wyrenderowano pod ekranem ładowania.
    @ObservationIgnored private(set) var warmFrames = 0

    func release() {
        holdStart = false
        #if DEBUG || FAMILY
        frameTimes = []
        raceClock = 0
        #endif
    }
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
    /// Otoczenie wzdłuż trasy — rysowane tylko w pobliżu gracza.
    @ObservationIgnored private var scenery: [(entity: Entity, s: Double)] = []
    @ObservationIgnored private var skyDome = Entity()
    @ObservationIgnored private var groundCenter = SIMD3<Float>(repeating: .infinity)
    @ObservationIgnored private var cullTimer = 0.0
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
        defer {
            #if DEBUG || FAMILY
            func models(_ e: Entity) -> Int { (e is ModelEntity ? 1 : 0) + e.children.reduce(0) { $0 + models($1) } }
            debugLog("wyścig: scena gotowa — razem \(models(root)) modeli (auta: \(cars.map { models($0.1.root) }))")
            #else
            debugLog("wyścig: scena gotowa")
            #endif
        }
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
            ImpostorLibrary.shared.purge()
            root.addChild(try TrackBuilder.build(track, theme: .of(spec.region), region: spec.region))
            scenery = TrackBuilder.cullables
            debugLog("wyścig: trasa zbudowana")
        } catch {
            assertionFailure("Nie udało się zbudować trasy: \(error)")
        }
        #if DEBUG || FAMILY
        func count(_ e: Entity) -> (models: Int, all: Int) {
            e.children.reduce((e is ModelEntity ? 1 : 0, 1)) { acc, c in let r = count(c); return (acc.0 + r.0, acc.1 + r.1) }
        }
        for (i, child) in root.children.enumerated() {
            for (j, sub) in child.children.enumerated() {
                let c = count(sub)
                if c.models > 20 { debugLog("scena: grupa \(i).\(j): \(c.models) modeli, \(c.all) encji") }
            }
        }
        debugLog("scena: trasa razem \(count(root).models) modeli")
        #endif
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

        let panorama = SkyEnvironment.panorama(spec.region)
        debugLog("wyścig: panorama…")
        skyDome = SkyEnvironment.panoramaDome(named: LocalAssets.regionKey(spec.region), radius: 2000)
            ?? SkyEnvironment.skyDome(radius: 2000)
        root.addChild(skyDome)
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

        debugLog("wyścig: panorama gotowa")
        SkyEnvironment.applyLighting(to: root, image: panorama ?? Materials.sky)
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

    /// Butla nitro: błyszcząca niebieska kapsuła (jedna siatka) w świetlistej poświacie — dwie części,
    /// bo przy kilkudziesięciu butlach na trasie każda część to osobne polecenie rysowania.
    private static func pickupModel() -> Entity {
        let e = Entity()
        let blue = UIColor(red: 0.15, green: 0.6, blue: 1, alpha: 1)
        var shell = PhysicallyBasedMaterial()
        shell.baseColor = .init(tint: blue)
        shell.emissiveColor = .init(color: blue)
        shell.emissiveIntensity = 1.8
        shell.metallic = 0.6
        shell.roughness = 0.2
        shell.clearcoat = 1.0
        let tank = ModelEntity(mesh: .generateBox(width: 0.6, height: 1.3, depth: 0.6, cornerRadius: 0.3), materials: [shell])
        e.addChild(tank)
        var haloMat = UnlitMaterial(color: UIColor(red: 0.4, green: 0.8, blue: 1, alpha: 1))
        haloMat.blending = .transparent(opacity: .init(floatLiteral: 0.2))
        e.addChild(ModelEntity(mesh: .generateSphere(radius: 0.8), materials: [haloMat]))
        return e
    }

    #if DEBUG || FAMILY
    /// Pomiar płynności: czasy klatek (s), przycięcia > 25 ms z chwilą i fazą.
    @ObservationIgnored private var frameTimes: [Double] = []
    @ObservationIgnored private var lastFrameAt = 0.0
    @ObservationIgnored private var raceClock = 0.0

    private func recordFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastFrameAt = now }
        guard lastFrameAt > 0 else { return }
        let ft = now - lastFrameAt
        raceClock += ft
        frameTimes.append(ft)
        if ft > 0.025 && raceClock > 0.5 {
            debugLog(String(format: "klatka: przycięcie %.0f ms (%.1f s wyścigu, faza %@)", ft * 1000, raceClock, "\(phase)"))
        }
        if frameTimes.count % 600 == 0 {
            let sorted = frameTimes.sorted()
            let p = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] * 1000 }
            let hitches = frameTimes.filter { $0 > 0.025 }.count
            debugLog(String(format: "klatki: %d, mediana %.1f ms, p95 %.1f ms, max %.0f ms, przycięć %d",
                            frameTimes.count, p(0.5), p(0.95), sorted.last! * 1000, hitches))
        }
    }
    #endif

    #if DEBUG || FAMILY
    @ObservationIgnored private var workTimes: [Double] = []
    @ObservationIgnored private var physTimes: [Double] = []
    @ObservationIgnored private var entTimes: [Double] = []
    #endif

    func update(dt rawDt: Double) {
        #if DEBUG || FAMILY
        recordFrame()
        let t0 = ProcessInfo.processInfo.systemUptime
        defer {
            workTimes.append(ProcessInfo.processInfo.systemUptime - t0)
            if workTimes.count % 600 == 0 {
                func p95(_ a: [Double]) -> Double { a.sorted()[Int(Double(a.count) * 0.95)] * 1000 }
                debugLog(String(format: "praca CPU w klatce: p95 %.2f ms (fizyka %.2f, encje %.2f), max %.1f ms",
                                p95(workTimes), p95(physTimes), p95(entTimes), workTimes.max()! * 1000))
            }
        }
        #endif
        let dt = min(rawDt, 0.05)
        input.poll()
        if paused {
            _ = input.consumeNitro() // wciśnięcia z czasu pauzy nie odpalają nitro po wznowieniu
            AudioManager.shared.setEngine(speed: 0, nitro: false, running: false)
            return
        }
        if holdStart {
            // Pod ekranem ładowania: auta na starcie, płomień i dym włączone (rozgrzewka efektów), zegar stoi.
            warmFrames += 1
            _ = input.consumeNitro()
            AudioManager.shared.setEngine(speed: 0, nitro: false, running: false)
            updateEntities()
            updateCamera(dt: dt)
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
            #if DEBUG || FAMILY
            let tp = ProcessInfo.processInfo.systemUptime
            #endif
            acc += dt
            while acc >= RaceSim.step {
                sim.advance()
                acc -= RaceSim.step
            }
            #if DEBUG || FAMILY
            physTimes.append(ProcessInfo.processInfo.systemUptime - tp)
            #endif
            handleEvents()
            if phase == .finished {
                finishTimer -= dt
                if finishTimer <= 0, let r = pendingResult {
                    result = r
                    pendingResult = nil
                }
            }
        }

        #if DEBUG || FAMILY
        let te = ProcessInfo.processInfo.systemUptime
        #endif
        updateEntities()
        updateCamera(dt: dt)
        #if DEBUG || FAMILY
        entTimes.append(ProcessInfo.processInfo.systemUptime - te)
        #endif
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

    /// Rywale i butle dalej niż tyle metrów (po trasie) od gracza nie są rysowane — i tak ledwo je widać.
    private static let drawDistance = 220.0

    private func setVisible(_ e: Entity, _ visible: Bool) {
        if e.isEnabled != visible { e.isEnabled = visible }
    }

    private func updateEntities() {
        let playerS = player.s
        for (car, e) in cars {
            let near = car.isPlayer || abs(wrapDelta(car.s, playerS, sim.track.length)) < Self.drawDistance
            setVisible(e.root, near)
            guard near else { continue }
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
            // Pierwsze klatki odliczania: płomień i dym pojawiają się na moment, zanim ruszy wyścig —
            // przygotowanie efektów nie wypada już na pierwsze nitro rywali po starcie.
            let rev = phase == .countdown && clock < 0.15
            e.setFlame(rev ? .normal : car.nitro.mode)
            e.setSmoke((rev && clock < 0.05) || car.drifting)
            e.spinWheels(distance: car.distance)
        }
        // Otoczenie: co 0,2 s ukrywamy obiekty dalej niż 320 m po trasie (bliżej przed autem widać dalej).
        cullTimer -= 1.0 / 60
        if cullTimer <= 0 {
            cullTimer = 0.2
            for item in scenery {
                let ahead = wrapDelta(item.s, playerS, sim.track.length)
                setVisible(item.entity, ahead > -120 && ahead < 320)
            }
        }
        // Butle wirują i unoszą się; zebrane znikają do czasu odnowienia.
        let spin = simd_quatf(angle: Float(clock * 2), axis: [0, 1, 0])
        let bob = Float(sin(clock * 3)) * 0.12
        for (i, e) in pickupEntities.enumerated() {
            let p = sim.pickups[i]
            let visible = p.isActive && abs(wrapDelta(p.s, playerS, sim.track.length)) < Self.drawDistance
            setVisible(e, visible)
            guard visible else { continue }
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
        // Panorama jedzie z kamerą: zdjęcie to „nieskończenie daleki” plan, horyzont się nie przesuwa.
        skyDome.position = from
        // Środek zanikania gruntu za kamerą — co kilka metrów wystarczy (podmiana materiału kosztuje).
        if var g = TrackBuilder.ground, simd_distance(from, groundCenter) > 4 {
            g.material.follow(from, on: g.entity)
            TrackBuilder.ground = g
            groundCenter = from
        }
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
