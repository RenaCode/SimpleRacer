import RaceCore
import RealityKit
import UIKit

/// Auto z prostych brył; przód auta patrzy w +Z.
@MainActor
final class CarEntity {
    /// Pozycja i kierunek auta.
    let root = Entity()
    /// Nadwozie — przechyla się w drifcie i koziołkuje przy rozbiciu.
    let body = Entity()
    private var paintParts: [ModelEntity] = []
    private var flames: [ModelEntity] = []
    private var wheels: [ModelEntity] = []
    private let wheelRadius: Float = 0.36

    init(def: CarDef, color: UIColor) {
        let s = def.shape
        let L = Float(s.length), W = Float(s.width), H = Float(s.height)
        root.addChild(body)

        let paint = Self.paint(color)
        let glass = SimpleMaterial(color: UIColor(red: 0.11, green: 0.17, blue: 0.23, alpha: 1), roughness: 0.1, isMetallic: true)
        let dark = SimpleMaterial(color: UIColor(white: 0.08, alpha: 1), roughness: 0.8, isMetallic: false)
        let headlight = UnlitMaterial(color: UIColor(red: 1, green: 0.97, blue: 0.85, alpha: 1))
        let taillight = UnlitMaterial(color: UIColor(red: 1, green: 0.12, blue: 0.12, alpha: 1))

        @discardableResult
        func box(_ w: Float, _ h: Float, _ l: Float, _ m: any Material, _ p: SIMD3<Float>, painted: Bool = false) -> ModelEntity {
            let e = ModelEntity(mesh: .generateBox(width: w, height: h, depth: l, cornerRadius: min(w, h, l) * 0.08), materials: [m])
            e.position = p
            body.addChild(e)
            if painted { paintParts.append(e) }
            return e
        }

        let baseH = H * 0.5
        box(W, baseH, L, paint, [0, 0.3 + baseH / 2, 0], painted: true)
        box(W * 0.98, baseH * 0.35, L * 0.25, paint, [0, 0.3 + baseH + 0.05, L * 0.3], painted: true) // maska
        let cabinH = H * 0.42
        let cabinL = L * Float(s.cabinLength), cabinZ = Float(s.cabinOffset)
        box(W * 0.8, cabinH, cabinL, glass, [0, 0.3 + baseH + cabinH / 2, cabinZ])
        box(W * 0.78, 0.06, cabinL * 0.8, paint, [0, 0.3 + baseH + cabinH + 0.03, cabinZ], painted: true)

        if s.spoiler {
            box(W * 0.95, 0.07, 0.45, paint, [0, 0.3 + baseH + 0.45, -L / 2 + 0.3], painted: true)
            box(0.08, 0.4, 0.1, dark, [W * 0.3, 0.3 + baseH + 0.22, -L / 2 + 0.3])
            box(0.08, 0.4, 0.1, dark, [-W * 0.3, 0.3 + baseH + 0.22, -L / 2 + 0.3])
        }
        for side: Float in [-1, 1] {
            box(W * 0.22, 0.12, 0.05, headlight, [side * W * 0.32, 0.3 + baseH * 0.7, L / 2 + 0.01])
            box(W * 0.25, 0.1, 0.05, taillight, [side * W * 0.3, 0.3 + baseH * 0.75, -L / 2 - 0.01])
        }

        let wheelMesh = MeshResource.generateCylinder(height: 0.3, radius: wheelRadius)
        for sx: Float in [-1, 1] {
            for sz: Float in [-1, 1] {
                let w = ModelEntity(mesh: wheelMesh, materials: [dark])
                w.position = [sx * (W / 2 - 0.08), wheelRadius, sz * L * 0.32]
                root.addChild(w)
                wheels.append(w)
            }
        }

        let flameMesh = MeshResource.generateCone(height: 1.3, radius: 0.18)
        for side: Float in [-1, 1] {
            let f = ModelEntity(mesh: flameMesh, materials: [Self.flame(.normal)])
            // Czubek stożka (domyślnie +Y) obrócony do tyłu auta (−Z).
            f.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            f.position = [side * W * 0.22, 0.45, -L / 2 - 0.65]
            f.isEnabled = false
            body.addChild(f)
            flames.append(f)
        }
        spinWheels(distance: 0)
    }

    private static func paint(_ color: UIColor) -> SimpleMaterial {
        SimpleMaterial(color: color, roughness: 0.3, isMetallic: true)
    }

    private static func flame(_ mode: NitroMode) -> UnlitMaterial {
        let color: UIColor = switch mode {
        case .off, .normal: UIColor(red: 0.3, green: 0.79, blue: 0.94, alpha: 1)
        case .perfect: UIColor(red: 0.71, green: 0.09, blue: 0.62, alpha: 1)
        case .shockwave: UIColor(red: 1, green: 0.62, blue: 0.11, alpha: 1)
        }
        var m = UnlitMaterial(color: color)
        m.blending = .transparent(opacity: .init(floatLiteral: 0.85))
        return m
    }

    func setColor(_ color: UIColor) {
        let m = Self.paint(color)
        for p in paintParts { p.model?.materials = [m] }
    }

    private var flameMode: NitroMode = .off

    func setFlame(_ mode: NitroMode) {
        if mode != flameMode {
            flameMode = mode
            for f in flames {
                f.isEnabled = mode != .off
                if mode != .off { f.model?.materials = [Self.flame(mode)] }
            }
        }
        guard mode != .off else { return }
        let base: Float = mode == .shockwave ? 1.6 : mode == .perfect ? 1.3 : 1
        for f in flames { f.scale = [base, base * Float.random(in: 0.85...1.15), base] }
    }

    func spinWheels(distance: Double) {
        let spin = simd_quatf(angle: Float(distance) / wheelRadius, axis: [1, 0, 0])
        // Walec stoi domyślnie wzdłuż Y — kładziemy go na bok, oś wzdłuż X.
        let lay = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        for w in wheels { w.orientation = spin * lay }
    }
}
