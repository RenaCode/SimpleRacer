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
        panorama(named: LocalAssets.regionKey(region))
    }

    /// Panorama `App/Sky/sky-<name>.jpg` (krainy albo "garage").
    static func panorama(named name: String) -> CGImage? {
        if let cached = panoramaCache[name] { return cached }
        guard let url = Bundle.main.url(forResource: "sky-\(name)", withExtension: "jpg"),
              let image = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        panoramaCache[name] = image
        return image
    }

    /// Małe kopie panoram (2048 px) — ten sam obraz przy każdym wyścigu, więc oświetlenie liczy się raz.
    private static var panoramaCache: [String: CGImage] = [:]

    static func skyDome(radius: Float, image: CGImage = Materials.sky) -> ModelEntity {
        var m = UnlitMaterial()
        if let tex = try? Materials.texture(image) {
            m.color = .init(tint: .white, texture: .init(tex))
        }
        m.faceCulling = .front
        return ModelEntity(mesh: .generateSphere(radius: radius), materials: [m])
    }

    /// Pas horyzontu w pełnej rozdzielczości (`sky-<name>-band.jpg`): ułamek wysokości zdjęcia od góry.
    /// Tam są budynki, drzewa i góry; niebo i grunt wystarczą w niskiej rozdzielczości.
    static func bandRange(_ name: String) -> ClosedRange<Float> {
        // W garażu kamera patrzy w dół na podłogę, więc pas sięga niżej.
        name == "garage" ? 0.30...0.80 : 0.25...0.53
    }

    /// Panorama na własnej kuli: całość z małego zdjęcia, a pas horyzontu z osobnej tekstury 8K —
    /// ostry horyzont bez kosztu pamięci pełnej panoramy 8K. `yaw` obraca zdjęcie wokół pionu.
    static func panoramaDome(named name: String, radius: Float, yaw: Float = 0) -> Entity? {
        // Tekstury z ScenePreloader (wczytane w tle); bez niego — wczytanie tutaj.
        guard let lowURL = Bundle.main.url(forResource: "sky-\(name)", withExtension: "jpg"),
              let low = texture(lowURL) else { return nil }
        let band = Bundle.main.url(forResource: "sky-\(name)-band", withExtension: "jpg").flatMap(texture)
        let v0 = bandRange(name).lowerBound, v1 = bandRange(name).upperBound
        let columns = 128
        func point(_ u: Float, _ v: Float) -> SIMD3<Float> {
            let phi = (u - 0.5) * 2 * .pi + yaw, theta = (0.5 - v) * .pi
            return SIMD3(sin(phi) * cos(theta), sin(theta), -cos(phi) * cos(theta)) * radius
        }
        /// Rząd czworokątów od v a do v b; `uv` zamienia (u, v) panoramy na współrzędne tekstury.
        func rows(_ b: inout MeshBuilder, from a: Float, to z: Float, steps: Int, uv: (Float, Float) -> SIMD2<Float>) {
            for r in 0..<steps {
                let va = a + (z - a) * Float(r) / Float(steps), vb = a + (z - a) * Float(r + 1) / Float(steps)
                for c in 0..<columns {
                    let ua = Float(c) / Float(columns), ub = Float(c + 1) / Float(columns)
                    b.quad(point(ua, vb), point(ub, vb), point(ub, va), point(ua, va),
                           uv: [uv(ua, vb), uv(ub, vb), uv(ub, va), uv(ua, va)])
                }
            }
        }
        var lowMesh = MeshBuilder(), bandMesh = MeshBuilder()
        let lowUV = { (u: Float, v: Float) in SIMD2<Float>(u, 1 - v) }
        if band != nil {
            rows(&lowMesh, from: 0, to: v0, steps: 24, uv: lowUV)
            rows(&bandMesh, from: v0, to: v1, steps: 16) { u, v in SIMD2(u, 1 - (v - v0) / (v1 - v0)) }
            rows(&lowMesh, from: v1, to: 1, steps: 24, uv: lowUV)
        } else {
            rows(&lowMesh, from: 0, to: 1, steps: 64, uv: lowUV)
        }
        let root = Entity()
        for (builder, tex) in [(lowMesh, Optional(low)), (bandMesh, band)] {
            guard let tex, !builder.isEmpty, let mesh = try? builder.mesh(name: "sky") else { continue }
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(tex))
            m.faceCulling = .none
            root.addChild(ModelEntity(mesh: mesh, materials: [m]))
        }
        return root
    }

    /// Tekstura z pliku: gotowa z ScenePreloader albo wczytana synchronicznie (zapas).
    static func texture(_ url: URL) -> TextureResource? {
        if let t = ScenePreloader.shared.texture(url) { return t }
        guard let image = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        if ScenePreloader.isRaw(url) {
            return try? TextureResource(image: image, options: .init(semantic: .raw, mipmapsMode: .allocateAndGenerateAll))
        }
        return try? Materials.texture(image)
    }

    /// Dodaje oświetlenie z nieba do `root` i podpina pod nie wszystkie modele w drzewie.
    static func applyLighting(to root: Entity, image: CGImage = Materials.sky, intensity: Float = 0.4) {
        // Środowiska liczymy po kolei (jedno naraz) i pamiętamy: dwa równoczesne liczenia oświetlenia
        // wywracały sterownik Metal w RealityKit (garaż i wyścig startujące w tej samej chwili).
        let previous = lightingQueue
        let task = Task { @MainActor () -> Void in
            await previous?.value
            let key = ObjectIdentifier(image)
            let env: EnvironmentResource
            if let cached = environments[key] {
                env = cached
            } else {
                // Do światła wystarczy mała kopia — pełna panorama tylko spowalnia start.
                let source = scaled(image, width: 1024) ?? image
                guard let made = try? await EnvironmentResource(equirectangular: source) else { return }
                environments[key] = made
                env = made
            }
            let ibl = Entity()
            ibl.components.set(ImageBasedLightComponent(source: .single(env), intensityExponent: intensity))
            root.addChild(ibl)
            attach(root, to: ibl)
        }
        lightingQueue = task
    }

    private static var lightingQueue: Task<Void, Never>?
    /// Policzone środowiska wg obrazu (panoramy są trzymane przez `panoramaCache`, więc klucz jest stabilny).
    private static var environments: [ObjectIdentifier: EnvironmentResource] = [:]

    private static func scaled(_ image: CGImage, width: Int) -> CGImage? {
        guard image.width > width else { return image }
        let height = width * image.height / image.width
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private static func attach(_ e: Entity, to ibl: Entity) {
        if e is ModelEntity { e.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ibl)) }
        for c in e.children { attach(c, to: ibl) }
    }
}
