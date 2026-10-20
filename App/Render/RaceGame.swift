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
    #if DEBUG || FAMILY
    @ObservationIgnored private var loggedDrift = false
    /// Liczniki dla testów UI (SimpleRacerUITests): wejścia gracza w drift, odpalenia nitro,
    /// klatki ze skrętem w lewo/prawo. Test czyta je z HUD (`testInfo`), bo nie widzi stanu gry.
    @ObservationIgnored private(set) var testDrifts = 0
    @ObservationIgnored private(set) var testNitros = 0
    @ObservationIgnored private(set) var testLeft = 0
    @ObservationIgnored private(set) var testRight = 0
    @ObservationIgnored private(set) var testAutoSteer = true
    var testInfo: String {
        "drifts=\(testDrifts) nitros=\(testNitros) left=\(testLeft) right=\(testRight) speed=\(Int(hud.speedKmh)) paused=\(paused ? 1 : 0)"
            + " lap=\(hud.lap) failed=\(buildFailed ? 1 : 0) cars=\(CarCatalog.all.count) car=\(player.def.id) auto=\(testAutoSteer ? 1 : 0)"
    }
    #endif
    @ObservationIgnored private let camera = PerspectiveCamera()
    @ObservationIgnored private let sim: RaceSim
    @ObservationIgnored private var cars: [(Car, CarEntity)] = []
    @ObservationIgnored private var pickupEntities: [Entity] = []
    /// Otoczenie wzdłuż trasy — rysowane tylko w pobliżu gracza.
    @ObservationIgnored private var scenery: [(entity: Entity, s: Double)] = []
    @ObservationIgnored private var skyDome = Entity()
    /// Grunt zanikający w oddali (przesuwany za kamerą); `nil`, gdy grunt jest zwykły.
    @ObservationIgnored private var ground: (entity: ModelEntity, material: GroundMaterial)?
    @ObservationIgnored private var groundCenter = SIMD3<Float>(repeating: .infinity)
    /// Kierunek jazdy aut w poprzedniej klatce i długość klatki — do prędkości kątowej.
    @ObservationIgnored private var lastYaw: [ObjectIdentifier: Double] = [:]
    @ObservationIgnored private var frameDt = 1.0 / 60
    @ObservationIgnored private let skidMarks = SkidMarks()
    @ObservationIgnored private var cullTimer = 0.0
    @ObservationIgnored private var clock = 0.0
    @ObservationIgnored private var countdown = RaceConfig.countdown
    @ObservationIgnored private var finishTimer = 0.0
    @ObservationIgnored private var acc = 0.0
    @ObservationIgnored private var camHeading = 0.0
    @ObservationIgnored private var fov = 70.0
    /// „Trauma” kamery (0…1): rośnie przy uderzeniach, maleje z czasem; wstrząs ∝ trauma².
    @ObservationIgnored private var shake = 0.0
    /// Odległość kamery za autem (sprężyna) i odrzut przy nitro / uderzeniu.
    @ObservationIgnored private var camBack = 6.2
    @ObservationIgnored private var camKick = 0.0
    @ObservationIgnored private var camHeight = 2.1
    /// Stan aut przed ostatnim krokiem fizyki — obraz rysuje pozycję pomiędzy nim a stanem bieżącym.
    @ObservationIgnored private var prevPoses: [ObjectIdentifier: Pose] = [:]
    /// Budowa trasy się nie udała — ekran wyścigu pokazuje komunikat zamiast pustej sceny.
    private(set) var buildFailed = false
    /// Obróbka obrazu dopasowana do krainy (kolor mgły z panoramy).
    @ObservationIgnored let postFX: PostFXSettings
    @ObservationIgnored private var hudTimer = 0.0
    @ObservationIgnored private var pendingResult: RaceResult?

    private static let rivals = ["Kuba", "Ola", "Marek", "Zosia", "Bartek", "Ewa", "Tomek"]

    @ObservationIgnored let spec: TrackSpec

    init(profile: Profile, spec: TrackSpec, playerCar: CarDef) {
        self.spec = spec
        var fx = PostFXSettings.forRegion(LocalAssets.regionKey(spec.region))
        // Poświata silnika (w HDR) zastępuje własną, liczoną z obrazu 8-bitowego.
        if CinematicLook.nativeBloom { fx.bloom = 0 }
        // Mgła jest w materiałach otoczenia (SceneHaze) — tekstura głębi w obróbce obrazu przychodzi pusta,
        // a gdyby na urządzeniu była pełna, mgła nałożyłaby się dwa razy.
        fx.fogDensity = 0
        postFX = fx
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
        #if DEBUG || FAMILY
        testAutoSteer = profile.autoSteer
        #endif
        let playerControl: Controller = profile.autoSteer ? AutoSteerController(input: input) : PlayerController(input: input)
        entries.append(Entry(name: "Ty", def: playerCar, color: profile.colorHex,
                             isPlayer: true, controller: playerControl))
        sim = RaceSim(track: track, entries: entries, laps: spec.laps)
        countdownText = String(Int(RaceConfig.countdown))

        do {
            ImpostorLibrary.shared.purge()
            root.addChild(try TrackBuilder.build(track, theme: .of(spec.region), region: spec.region))
            scenery = TrackBuilder.cullables
            ground = TrackBuilder.ground
            // Wyścig trzyma swoje odwołania; statyczne pola nie przetrzymują trasy po jego końcu.
            TrackBuilder.release()
            debugLog("wyścig: trasa zbudowana")
        } catch {
            debugLog("wyścig: BŁĄD budowy trasy: \(error)")
            buildFailed = true
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
            e.addContactShadow()
            root.addChild(e.root)
            cars.append((car, e))
        }
        debugLog("wyścig: auta gotowe")

        // Słońce z panoramy krainy: kierunek z najjaśniejszego miejsca nieba, barwa z jego otoczenia —
        // cienie padają tam, gdzie wskazuje zdjęcie, a światło ma kolor nieba, nie czystą biel.
        let sunInfo = SunEstimate.from(region: LocalAssets.regionKey(spec.region))
        let sun = DirectionalLight()
        sun.light.intensity = 3500
        sun.light.color = sunInfo.color
        if #available(iOS 18.0, *) {
            sun.shadow = DirectionalLightComponent.Shadow(shadowProjection: .automatic(maximumDistance: 80), depthBias: 2)
        }
        sun.look(at: .zero, from: sunInfo.direction * 160, relativeTo: nil)
        root.addChild(sun)
        debugLog(String(format: "słońce: kierunek (%.2f, %.2f, %.2f), z panoramy: %@", sunInfo.direction.x, sunInfo.direction.y,
                        sunInfo.direction.z, sunInfo.fromPhoto ? "tak" : "nie"))

        let panorama = SkyEnvironment.panorama(spec.region)
        debugLog("wyścig: panorama…")
        skyDome = SkyEnvironment.panoramaDome(named: LocalAssets.regionKey(spec.region), radius: 2000)
            ?? SkyEnvironment.skyDome(radius: 2000)
        root.addChild(skyDome)
        root.addChild(skidMarks.entity)
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
        CinematicLook.apply(root: root, camera: camera)

        debugLog("wyścig: panorama gotowa")
        SkyEnvironment.applyLighting(to: root, image: panorama ?? Materials.sky)
        #if DEBUG || FAMILY
        // Do zrzutów ekranu wyników: `-finishSoon` stawia gracza 150 m przed metą.
        if ProcessInfo.processInfo.arguments.contains("-finishSoon") {
            player.distance = sim.raceDistance - 150
            player.s = wrap(player.distance, track.length)
        }
        // `-shotAt <s>`: stały kadr do porównań wyglądu — gracz stoi w punkcie s, rywale 300 m dalej
        // (poza zasięgiem rysowania), fizyka i odliczanie stoją. Ten sam obraz przy każdym uruchomieniu.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-shotAt"), i + 1 < args.count, let s = Double(args[i + 1]) {
            shotMode = true
            countdownText = nil
            clock = 1 // poza oknem rozgrzewki płomienia i dymu na starcie
            for car in sim.cars {
                car.distance = car.isPlayer ? s : s + 300
                car.s = wrap(car.distance, track.length)
                car.d = car.isPlayer ? 0 : car.d
            }
        }
        #endif
        camHeading = track.sample(at: player.s).heading
        updateEntities()
        updateCamera(dt: 1)
    }

    private var player: Car { sim.player! }

    /// Położenie auta do rysowania. Fizyka liczy się stałym krokiem 1/120 s, a klatki przychodzą
    /// w swoim rytmie (60/120 Hz, z wahaniami) — bez interpolacji auto co którąś klatkę stoi, a w następnej
    /// przeskakuje o dwa kroki (przy 250 km/h to ok. pół metra). Rysujemy stan pomiędzy dwoma ostatnimi
    /// krokami fizyki (`acc / step`), jak w „Fix Your Timestep” — ruch jest równy przy każdym odświeżaniu.
    struct Pose {
        var s, d, alphaVel, slide, distance: Double
        init(_ car: Car) { s = car.s; d = car.d; alphaVel = car.alphaVel; slide = car.slide; distance = car.distance }
        var alphaFace: Double { alphaVel + slide }
    }

    private func pose(_ car: Car) -> Pose {
        var cur = Pose(car)
        guard phase != .countdown, let p = prevPoses[ObjectIdentifier(car)] else { return cur }
        let a = min(1, max(0, acc / RaceSim.step))
        let L = sim.track.length
        cur.s = wrap(p.s + wrapDelta(cur.s, p.s, L) * a, L)
        cur.d = p.d + (cur.d - p.d) * a
        cur.alphaVel = p.alphaVel + (cur.alphaVel - p.alphaVel) * a
        cur.slide = p.slide + (cur.slide - p.slide) * a
        cur.distance = p.distance + (cur.distance - p.distance) * a
        return cur
    }

    /// Butla nitro: fotorealistyczna butla podtlenku azotu z delikatną poświatą (`NitroCanister`) — dwie encje,
    /// bo przy kilkudziesięciu butlach na trasie każda część to osobne polecenie rysowania.
    private static func pickupModel() -> Entity {
        NitroCanister.make()
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
                // Fizyka i encje nie liczą się pod ekranem ładowania, w pauzie ani w kadrze `-shotAt` — ich tablice
                // bywają puste, gdy praca w klatce ma już 600 pomiarów.
                func p95(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[Int(Double(a.count) * 0.95)] * 1000 }
                debugLog(String(format: "praca CPU w klatce: p95 %.2f ms (fizyka %.2f, encje %.2f), max %.1f ms",
                                p95(workTimes), p95(physTimes), p95(entTimes), workTimes.max()! * 1000))
            }
        }
        #endif
        let dt = min(rawDt, 0.05)
        frameDt = max(dt, 1.0 / 240)
        input.poll()
        if paused {
            _ = input.consumeNitro() // wciśnięcia z czasu pauzy nie odpalają nitro po wznowieniu
            AudioManager.shared.setEngine(speed: 0, nitro: false, running: false)
            return
        }
        #if DEBUG || FAMILY
        if shotMode {
            warmFrames += 1 // ekran ładowania czeka na rozgrzane klatki
            updateEntities()
            updateCamera(dt: dt)
            return
        }
        #endif
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
        #if DEBUG || FAMILY
        if input.steer > 0.5 { testLeft += 1 }
        if input.steer < -0.5 { testRight += 1 }
        if p.drifting != loggedDrift {
            loggedDrift = p.drifting
            if p.drifting { testDrifts += 1 }
            debugLog(String(format: "gracz: drift %@ przy %.0f km/h", p.drifting ? "start" : "koniec", p.speed * 3.6))
        }
        #endif
        AudioManager.shared.setEngine(speed: p.speed / p.def.topSpeed, nitro: p.nitro.mode != .off, running: !p.wrecked,
                                      slip: abs(p.slide) / Physics.driftSlideAngle, drifting: p.drifting)
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
                for car in sim.cars { prevPoses[ObjectIdentifier(car)] = Pose(car) }
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
                    Haptics.shared.pulse(intensity: 0.8, sharpness: 0.7, duration: 0.25)
                    shake = max(shake, 0.6)
                } else if victim === p {
                    toast("ROZBITY!", .bad)
                }
            case let .wreck(car) where car === p:
                debugLog(String(format: "gracz: rozbity przy %.0f km/h, d=%.2f m, czas %.1f s", car.speed * 3.6, car.d, sim.time))
                shake = 1
                Haptics.shared.pulse(intensity: 1, sharpness: 0.3, duration: 0.5)
                AudioManager.shared.play(.crash)
                let byRival = events.contains { if case let .takedown(_, v) = $0 { return v === p }; return false }
                if !byRival { toast("ROZBITY!", .bad) }
            case let .nitro(car, mode) where car === p:
                #if DEBUG || FAMILY
                testNitros += 1
                #endif
                AudioManager.shared.play(.nitro)
                camKick = mode == .shockwave ? 1.4 : 0.9
                Haptics.shared.pulse(intensity: mode == .shockwave ? 1 : 0.6, sharpness: 0.4, duration: 0.35)
                if mode == .perfect { toast("PERFECT NITRO", .good) }
                if mode == .shockwave {
                    toast("FALA UDERZENIOWA", .good)
                    shake = max(shake, 0.55)
                }
            case .nearMiss:
                toast("NA WŁOS! +nitro", .info)
            case let .driftBoost(car) where car === p:
                toast("MINI-TURBO!", .good)
                AudioManager.shared.play(.nitro)
                camKick = 0.6
            case let .wallHit(car, intensity):
                // Uderzenie w bandę: iskry u każdego auta w pobliżu, wstrząs tylko u gracza.
                if let e = cars.first(where: { $0.0 === car })?.1 {
                    e.sparks(side: car.d > 0 ? 1 : -1, intensity: intensity)
                }
                if car === p {
                    shake = max(shake, min(0.7, 0.2 + intensity / 25))
                    AudioManager.shared.impact(intensity: min(1, intensity / 25))
                    Haptics.shared.pulse(intensity: Float(min(1, 0.3 + intensity / 25)), sharpness: 0.8)
                }
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
    /// Wierzch asfaltu (TrackBuilder kładzie jezdnię na y 0,02) — na nim stoją opony.
    static let roadSurface: Float = 0.02
    #if DEBUG || FAMILY
    /// `-shotAt`: zamrożony kadr do zrzutów porównawczych.
    @ObservationIgnored private var shotMode = false
    private static let sideCam = ProcessInfo.processInfo.arguments.contains("-sideCam")
    #endif

    private func setVisible(_ e: Entity, _ visible: Bool) {
        if e.isEnabled != visible { e.isEnabled = visible }
    }

    private func updateEntities() {
        let playerS = player.s
        for (car, e) in cars {
            let near = car.isPlayer || abs(wrapDelta(car.s, playerS, sim.track.length)) < Self.drawDistance
            setVisible(e.root, near)
            guard near else { continue }
            let pose = pose(car)
            let w = sim.track.toWorld(s: pose.s, d: pose.d)
            e.root.position = [Float(w.x), Self.roadSurface, Float(w.z)]
            e.root.orientation = simd_quatf(angle: Float(w.heading + pose.alphaFace), axis: [0, 1, 0])
            if car.wrecked {
                e.setWreck(Float(1 - car.wreckTimer / Physics.wreckTime))
            } else {
                // Prędkość kątowa toru jazdy (do skrętu kół i przechyłu na zawieszeniu).
                let yaw = w.heading + pose.alphaVel
                let id = ObjectIdentifier(car)
                let yawRate = lastYaw[id].map { wrapAngle(yaw - $0) / frameDt } ?? 0
                lastYaw[id] = yaw
                e.updateSuspension(yawRate: yawRate, speed: car.speed, slide: pose.slide, dt: frameDt,
                                   steerInput: car.isPlayer ? car.lastSteer : nil)
            }
            // Pierwsze klatki odliczania: płomień i dym pojawiają się na moment, zanim ruszy wyścig —
            // przygotowanie efektów nie wypada już na pierwsze nitro rywali po starcie.
            let rev = phase == .countdown && clock < 0.15
            e.setFlame(rev ? .normal : car.nitro.mode)
            e.setSmoke((rev && clock < 0.05) || car.drifting, viewer: camera.position)
            e.spinWheels(distance: pose.distance)
            // Ślady opon: w drifcie, gdy auto jest blisko gracza (dalej i tak ich nie widać).
            if abs(wrapDelta(car.s, playerS, sim.track.length)) < 80 {
                let base = cars.firstIndex { $0.0 === car }.map { $0 * 4 } ?? 0
                for (i, p) in e.rearContacts().enumerated() {
                    skidMarks.track(key: base + i, at: p, active: car.drifting && !car.wrecked && car.speed > 8)
                }
            }
        }
        skidMarks.flush(dt: frameDt)
        // Otoczenie: co 0,2 s ukrywamy obiekty dalej niż 320 m po trasie (bliżej przed autem widać dalej).
        cullTimer -= frameDt
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
        let pp = pose(p)
        let w = sim.track.toWorld(s: pp.s, d: pp.d)
        // Kamera podąża za torem jazdy, nie za przodem auta — w drifcie widać poślizg.
        camHeading = dampAngle(camHeading, w.heading + pp.alphaVel, rate: 6, dt: dt)
        let fx = sin(camHeading), fz = cos(camHeading)
        // Kamera na sprężynie: przy nitro odjeżdża do tyłu i obniża się (auto „ucieka” do przodu),
        // odrzut (`camKick`) dokłada szarpnięcie w chwili odpalenia lub uderzenia.
        let nitroOn = p.nitro.mode != .off
        camBack = damp(camBack, 6.2 + p.speed * 0.02 + (nitroOn ? 0.9 : 0), rate: 3, dt: dt)
        camHeight = damp(camHeight, nitroOn ? 1.85 : 2.1, rate: 3, dt: dt)
        camKick = damp(camKick, 0, rate: 5, dt: dt)
        let back = camBack + camKick
        // Wstrząs z gładkiego szumu (suma sinusów o niewspółmiernych częstotliwościach), nie z losowania
        // co klatkę — uderzenie „bije” i wygasa, zamiast brzęczeć. Amplituda ∝ trauma².
        shake = max(0, shake - dt * 1.2)
        let trauma = min(1, shake) * min(1, shake) + (p.nitro.mode == .shockwave ? 0.03 : 0)
        let t = clock * 28
        let nx = (sin(t * 1.0) + sin(t * 2.31 + 1.3) * 0.5) / 1.5
        let ny = (sin(t * 1.47 + 0.7) + sin(t * 2.93 + 2.1) * 0.5) / 1.5
        let side = SIMD3<Double>(fz, 0, -fx) * nx * trauma * 0.35
        var from = SIMD3<Float>(Float(w.x - fx * back + side.x), Float(camHeight + ny * trauma * 0.25), Float(w.z - fz * back + side.z))
        var at = SIMD3<Float>(Float(w.x + fx * 6), 1.15, Float(w.z + fz * 6))
        #if DEBUG || FAMILY
        // `-sideCam`: kamera nisko z boku auta gracza — do sprawdzania styku opon z jezdnią.
        if Self.sideCam {
            at = SIMD3<Float>(Float(w.x), 0.3, Float(w.z))
            from = at + SIMD3<Float>(Float(fz) * 4.5 + Float(fx) * 1.2, 0.35, Float(-fx) * 4.5 + Float(fz) * 1.2)
        }
        #endif
        camera.look(at: at, from: from, relativeTo: nil)
        // Panorama jedzie z kamerą: zdjęcie to „nieskończenie daleki” plan, horyzont się nie przesuwa.
        skyDome.position = from
        // Środek zanikania gruntu za kamerą — co kilka metrów wystarczy (podmiana materiału kosztuje).
        if var g = ground, simd_distance(from, groundCenter) > 4 {
            g.material.follow(from, on: g.entity)
            ground = g
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
