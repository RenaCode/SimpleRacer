import RaceCore
import RealityKit
import UIKit

/// Niebo widoczne w tle i to samo niebo jako źródło światła oraz odbić (IBL) — lakier odbija chmury i słońce.
///
/// W wyścigu tłem jest zdjęcie panoramiczne krainy (jak w grach mobilnych: daleki plan to obraz, nie modele 3D),
/// rozpięte na kuli, która jedzie razem z kamerą — horyzont zostaje na swoim miejscu, a kosztuje jedno rysowanie.
@MainActor
enum SkyEnvironment {
    /// Panorama krainy z paczki aplikacji (App/Sky, CC0 Poly Haven); `nil`, gdy pliku brak.
    static func panorama(_ region: Region) -> CGImage? {
        guard let url = Bundle.main.url(forResource: "sky-\(LocalAssets.regionKey(region))", withExtension: "jpg"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        return image.cgImage
    }

    static func skyDome(radius: Float, image: CGImage = Materials.sky) -> ModelEntity {
        var m = UnlitMaterial()
        if let tex = try? Materials.texture(image) {
            m.color = .init(tint: .white, texture: .init(tex))
        }
        m.faceCulling = .front
        return ModelEntity(mesh: .generateSphere(radius: radius), materials: [m])
    }

    /// Dodaje oświetlenie z nieba do `root` i podpina pod nie wszystkie modele w drzewie.
    static func applyLighting(to root: Entity, image: CGImage = Materials.sky, intensity: Float = 0.4) {
        Task { @MainActor in
            // Do światła wystarczy mała kopia — pełna panorama tylko spowalnia start.
            let source = scaled(image, width: 1024) ?? image
            guard let env = try? await EnvironmentResource(equirectangular: source) else { return }
            let ibl = Entity()
            ibl.components.set(ImageBasedLightComponent(source: .single(env), intensityExponent: intensity))
            root.addChild(ibl)
            attach(root, to: ibl)
        }
    }

    private static func scaled(_ image: CGImage, width: Int) -> CGImage? {
        guard image.width > width else { return image }
        let height = width * image.height / image.width
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private static func attach(_ e: Entity, to ibl: Entity) {
        if e is ModelEntity { e.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ibl)) }
        for c in e.children { attach(c, to: ibl) }
    }
}
