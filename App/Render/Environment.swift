import RealityKit
import UIKit

/// Niebo widoczne w tle i to samo niebo jako źródło światła oraz odbić (IBL) — lakier odbija chmury i słońce.
@MainActor
enum SkyEnvironment {
    static func skyDome(radius: Float) -> Entity {
        var m = UnlitMaterial()
        if let tex = try? Materials.texture(Materials.sky) {
            m.color = .init(tint: .white, texture: .init(tex))
        }
        m.faceCulling = .front
        return ModelEntity(mesh: .generateSphere(radius: radius), materials: [m])
    }

    /// Dodaje oświetlenie z nieba do `root` i podpina pod nie wszystkie modele w drzewie.
    static func applyLighting(to root: Entity) {
        Task { @MainActor in
            guard let env = try? await EnvironmentResource(equirectangular: Materials.sky) else { return }
            let ibl = Entity()
            ibl.components.set(ImageBasedLightComponent(source: .single(env), intensityExponent: 0.4))
            root.addChild(ibl)
            attach(root, to: ibl)
        }
    }

    private static func attach(_ e: Entity, to ibl: Entity) {
        if e is ModelEntity { e.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ibl)) }
        for c in e.children { attach(c, to: ibl) }
    }
}
