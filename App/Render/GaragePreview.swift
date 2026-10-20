import RaceCore
import RealityKit
import UIKit

/// Obracające się auto na podeście — tło menu i garażu.
@MainActor
final class GaragePreview {
    enum Layout { case menu, garage }

    let root = Entity()
    var subscription: EventSubscription?
    private let camera = PerspectiveCamera()
    private let turntable = Entity()
    private var car: CarEntity?
    private var carId = ""
    private var colorHex = ""
    private var angle: Float = 0.6
    private var backdrop = Entity()
    private var carShadow = Entity()

    init() {
        ImpostorLibrary.warmUp()
        // Obrotnica jak w salonie: cokół stoi, tarcza z autem się obraca.
        let podium = Podium.make()
        root.addChild(podium.base)
        turntable.addChild(podium.top)
        carShadow = podium.shadow
        carShadow.isEnabled = false
        root.addChild(turntable)

        // Tło: do czasu wczytania panoramy (w tle, `loadBackdrop`) ciemna kula — start aplikacji nie czeka na 8K.
        var bg = UnlitMaterial(color: UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1))
        bg.faceCulling = .front
        backdrop = ModelEntity(mesh: .generateSphere(radius: 80), materials: [bg])
        root.addChild(backdrop)

        let key = DirectionalLight()
        key.light.intensity = 3000
        key.look(at: .zero, from: [3, 9, 6], relativeTo: nil)
        root.addChild(key)
        let spot = SpotLight()
        spot.light.intensity = 40000
        spot.look(at: .zero, from: [0, 9, 3], relativeTo: nil)
        root.addChild(spot)

        camera.camera.fieldOfViewInDegrees = 40
        root.addChild(camera)
        CinematicLook.apply(root: root, camera: camera)
        setLayout(.menu, narrow: false)
    }

    private var realisticShown = false
    /// Scena podpięta do RealityView — od tej chwili RealityKit jest zainicjalizowany i można tworzyć tekstury w tle.
    var attached = false
    private var eye: SIMD3<Float> = [0, 3.4, 10]
    private var floor: (entity: ModelEntity, material: GroundMaterial)?

    /// Zanikanie posadzki liczone od kamery.
    private func placeFloor() {
        guard var f = floor else { return }
        f.material.follow(eye, on: f.entity)
        floor = f
    }

    /// Zdjęcie hali (CC0) jako tło i źródło odbić — tekstury wczytane w tle przez ScenePreloader.
    func loadBackdrop() async {
        await ScenePreloader.shared.prepareGarage()
        // Kamera patrzy na niebieską ścianę z barierami z opon (zdjęcie obrócone o −90°).
        guard let dome = SkyEnvironment.panoramaDome(named: "garage", radius: 80, yaw: -.pi / 2) else { return }
        backdrop.removeFromParent()
        backdrop = dome
        backdrop.position = eye
        root.addChild(dome)
        // Posadzka pod podestem: zasłania opony stojące na zdjęciu tuż przy aparacie (podest je przecinał)
        // i w oddali przechodzi w posadzkę ze zdjęcia.
        if let url = Bundle.main.url(forResource: "floor-garage", withExtension: "jpg"),
           let tex = SkyEnvironment.texture(url),
           let material = GroundMaterial.make(tex, tile: 3, fadeStart: 16) {
            var b = MeshBuilder()
            let g: Float = 120
            b.quad([-g, -0.42, g], [g, -0.42, g], [g, -0.42, -g], [-g, -0.42, -g])
            if let mesh = try? b.mesh(name: "garage-floor") {
                let e = ModelEntity(mesh: mesh, materials: [material.material])
                root.addChild(e)
                floor = (e, material)
                placeFloor()
            }
        }
        if let photo = SkyEnvironment.panorama(named: "garage") {
            SkyEnvironment.applyLighting(to: root, image: photo, intensity: 0.8, yaw: -.pi / 2)
        }
        #if DEBUG || FAMILY
        // `-probe`: lustrzana i biała kula obok podestu — do porównań oświetlenia (odbicia, kierunek światła).
        if ProcessInfo.processInfo.arguments.contains("-probe") {
            var white = PhysicallyBasedMaterial()
            white.baseColor = .init(tint: UIColor(white: 0.8, alpha: 1))
            white.roughness = 0.9
            var mirror = PhysicallyBasedMaterial()
            mirror.baseColor = .init(tint: .white)
            mirror.metallic = 1.0
            mirror.roughness = 0.0
            for (x, material) in [(Float(-1.3), mirror), (1.3, white)] {
                let ball = ModelEntity(mesh: .generateSphere(radius: 0.45), materials: [material])
                ball.position = [x, 2.3, 0]
                root.addChild(ball)
            }
        }
        #endif
    }

    func show(def: CarDef, colorHex: String) {
        let realisticReady = def.realistic.map { LocalAssets.shared.templates[$0.file] != nil } ?? false
        // Auto z własnym modelem pokazujemy dopiero po jego wczytaniu — bez migania modelu zastępczego.
        if def.realistic != nil && !realisticReady {
            car?.root.removeFromParent()
            car = nil
            carId = ""
            carShadow.isEnabled = false
            return
        }
        carShadow.isEnabled = true
        if let car, carId == def.id, realisticShown == realisticReady {
            if colorHex != self.colorHex { car.setColor(UIColorHex.color(colorHex)) }
        } else {
            car?.root.removeFromParent()
            let c = CarEntity(def: def, color: UIColorHex.color(colorHex))
            turntable.addChild(c.root)
            car = c
            carId = def.id
            realisticShown = realisticReady
        }
        self.colorHex = colorHex
    }

    /// W menu przyciski są z lewej, w garażu panel z prawej — auto staje po drugiej stronie.
    func setLayout(_ layout: Layout, narrow: Bool) {
        // Garaż: panel zajmuje ok. 60% szerokości po prawej, więc auto (obracające się, ok. 5,2 m średnicy)
        // musi zmieścić się w lewych 40%. Kamera dalej (14 m) i patrzy w prawo od auta, żeby stało na środku
        // wolnej części: przesunięcie ≈ 0,31 × odległość.
        // Menu: kolumna przycisków zajmuje prawe ~36%, więc auto stoi ok. 1/3 szerokości od lewej.
        // W menu kamera niżej i bliżej — auto duże, jak na makiecie, podest tylko pod nim.
        let menu = layout == .menu && !narrow
        let distance: Float = narrow ? 13 : (layout == .garage ? 14 : 9)
        let target: SIMD3<Float> = narrow ? [0, -1.2, 0] : (layout == .garage ? [0.31 * distance, 0.5, 0] : [0.19 * distance, 1.0, 0])
        eye = [0, menu ? 2.1 : 3.4, distance]
        camera.look(at: target, from: eye, relativeTo: nil)
        // Panorama wyśrodkowana na kamerze — perspektywa zdjęcia zgadza się z widokiem.
        backdrop.position = eye
        placeFloor()
    }

    func update(dt: Double) {
        angle += Float(dt) * 0.5
        turntable.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
    }
}
