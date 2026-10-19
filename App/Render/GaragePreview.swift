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
    private var backdrop = ModelEntity()

    init() {
        let floor = ModelEntity(mesh: .generateCylinder(height: 0.25, radius: 4.3),
                                materials: [SimpleMaterial(color: UIColor(red: 0.17, green: 0.18, blue: 0.23, alpha: 1), roughness: 0.5, isMetallic: true)])
        floor.position.y = -0.13
        turntable.addChild(floor)
        let ring = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: 4.45),
                               materials: [UnlitMaterial(color: UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1))])
        ring.position.y = -0.14
        turntable.addChild(ring)
        root.addChild(turntable)

        // Tło: zdjęcie panoramiczne prawdziwego warsztatu (CC0) — ono też oświetla lakier i daje odbicia.
        let photo = SkyEnvironment.panorama(named: "garage")
        if let photo {
            backdrop = SkyEnvironment.skyDome(radius: 80, image: photo)
        } else {
            var bg = UnlitMaterial(color: UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1))
            bg.faceCulling = .front
            backdrop = ModelEntity(mesh: .generateSphere(radius: 80), materials: [bg])
        }
        root.addChild(backdrop)

        SkyEnvironment.applyLighting(to: root, image: photo ?? Materials.sky, intensity: photo == nil ? 0.4 : 0.8)
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
        setLayout(.menu, narrow: false)
    }

    private var realisticShown = false

    func show(def: CarDef, colorHex: String) {
        let realisticReady = def.realistic.map { LocalAssets.shared.templates[$0.file] != nil } ?? false
        // Auto z własnym modelem pokazujemy dopiero po jego wczytaniu — bez migania modelu zastępczego.
        if def.realistic != nil && !realisticReady {
            car?.root.removeFromParent()
            car = nil
            carId = ""
            return
        }
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
        let distance: Float = narrow ? 13 : (layout == .garage ? 14 : 10)
        let target: SIMD3<Float> = narrow ? [0, -1.2, 0] : (layout == .garage ? [0.31 * distance, 0.5, 0] : [-2.2, 0.6, 0])
        let eye: SIMD3<Float> = [0, 3.4, distance]
        camera.look(at: target, from: eye, relativeTo: nil)
        // Panorama wyśrodkowana na kamerze — perspektywa zdjęcia zgadza się z widokiem.
        backdrop.position = eye
    }

    func update(dt: Double) {
        angle += Float(dt) * 0.5
        turntable.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
    }
}
