import CoreGraphics
import Metal
import RealityKit
import UIKit

/// Materiały i tekstury generowane w kodzie (bez plików graficznych).
@MainActor
enum Materials {
    /// Lakier fabryczny: kolorowa baza pod warstwą bezbarwnego lakieru — odbija niebo i otoczenie.
    static func paint(_ color: UIColor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        applyPaint(&m, color)
        return m
    }

    /// Lakier metalik: przyciemniona baza (×0,85 — jasny kolor pod silnym światłem przepalał się w płaski róż)
    /// z metalicznością 0,6 — boki odbijają otoczenie (skały, mury), kolor ma głębię; połysk daje gładka warstwa
    /// bezbarwna. Porównane na zrzutach z lakierem niemetalicznym (metallic 0): ten był płaski i różowy.
    /// Szorstkość warstwy nie schodzi poniżej ~0,05: lustro migocze na krawędziach przy ruchu kamery.
    static func applyPaint(_ m: inout PhysicallyBasedMaterial, _ color: UIColor) {
        let p = paintParams
        m.baseColor = .init(tint: scaled(color, p.albedo))
        m.metallic = .init(floatLiteral: p.metallic)
        m.roughness = .init(floatLiteral: p.roughness)
        m.specular = .init(floatLiteral: p.specular)
        m.clearcoat = 1.0
        m.clearcoatRoughness = .init(floatLiteral: p.clearcoatRoughness)
    }

    struct PaintParams { var metallic: Float, roughness: Float, specular: Float, clearcoatRoughness: Float, albedo: Float }

    static let paintParams: PaintParams = {
        var p = PaintParams(metallic: 0.6, roughness: 0.35, specular: 0.5, clearcoatRoughness: 0.05, albedo: 0.85)
        #if DEBUG || FAMILY
        // Strojenie bez przebudowy: `-paint metallic,roughness,specular,clearcoatRoughness,albedo`.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-paint"), i + 1 < args.count {
            let v = args[i + 1].split(separator: ",").compactMap { Float($0) }
            if v.count == 5 { p = PaintParams(metallic: v[0], roughness: v[1], specular: v[2], clearcoatRoughness: v[3], albedo: v[4]) }
        }
        #endif
        return p
    }()

    /// Kolor przyciemniony mnożnikiem składowych sRGB (barwa i nasycenie bez zmian).
    static func scaled(_ c: UIColor, _ k: Float) -> UIColor {
        guard k != 1 else { return c }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        let f = CGFloat(k)
        return UIColor(red: r * f, green: g * f, blue: b * f, alpha: a)
    }

    /// Szyba: gładka, z pełnym odbiciem nieba. Barwa i krycie zostają z modelu — część modeli nie ma
    /// wnętrza i przez bardziej przezroczystą szybę widać pustkę.
    static func applyGlass(_ m: inout PhysicallyBasedMaterial) {
        m.metallic = 0.0
        m.roughness = 0.03
        m.specular = 1.0
    }

    static let glass: PhysicallyBasedMaterial = {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: 0.04, green: 0.06, blue: 0.09, alpha: 1))
        m.metallic = 0.9
        m.roughness = 0.04
        m.clearcoat = 1.0
        return m
    }()

    static let chrome: PhysicallyBasedMaterial = {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(white: 0.85, alpha: 1))
        m.metallic = 1.0
        m.roughness = 0.15
        return m
    }()

    static func matte(_ color: UIColor, roughness: Float = 0.85, metallic: Float = 0) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.roughness = .init(floatLiteral: roughness)
        m.metallic = .init(floatLiteral: metallic)
        return m
    }

    static func glow(_ color: UIColor, intensity: Float = 2) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.emissiveColor = .init(color: color)
        m.emissiveIntensity = intensity
        return m
    }

    /// Materiał z powtarzaną teksturą (UV > 1 kafelkuje zamiast rozciągać).
    static func tiled(_ image: CGImage, roughness: Float = 0.9, metallic: Float = 0) -> PhysicallyBasedMaterial {
        guard let tex = try? texture(image) else {
            var m = PhysicallyBasedMaterial()
            m.roughness = .init(floatLiteral: roughness)
            m.metallic = .init(floatLiteral: metallic)
            return m
        }
        return tiled(tex, roughness: roughness, metallic: metallic)
    }

    static func tiled(_ tex: TextureResource, roughness: Float = 0.9, metallic: Float = 0) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.roughness = .init(floatLiteral: roughness)
        m.metallic = .init(floatLiteral: metallic)
        let s = MTLSamplerDescriptor()
        s.sAddressMode = .repeat
        s.tAddressMode = .repeat
        s.minFilter = .linear
        s.magFilter = .linear
        s.mipFilter = .linear
        s.maxAnisotropy = 8
        m.baseColor = .init(tint: .white, texture: .init(tex, sampler: .init(s)))
        return m
    }

    static func texture(_ image: CGImage) throws -> TextureResource {
        try TextureResource(image: image, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
    }

    /// Rysuje obraz w pamięci. Układ współrzędnych CG: y rośnie w górę, (0,0) to lewy dolny róg.
    static func image(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return ctx.makeImage()!
    }

    static let roadSurface: CGImage = image(width: 256, height: 256) { g in
        g.setFillColor(UIColor(red: 0.2, green: 0.21, blue: 0.23, alpha: 1).cgColor)
        g.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            let v = CGFloat.random(in: 0.12...0.36, using: &rng)
            g.setFillColor(UIColor(white: v, alpha: 0.55).cgColor)
            g.fill(CGRect(x: .random(in: 0..<256, using: &rng), y: .random(in: 0..<256, using: &rng), width: 1.5, height: 1.5))
        }
        // Delikatne smugi wzdłuż jazdy — ślady opon.
        for x in [70.0, 100.0, 156.0, 186.0] {
            g.setFillColor(UIColor(white: 0.08, alpha: 0.12).cgColor)
            g.fill(CGRect(x: x, y: 0, width: 14, height: 256))
        }
    }

    /// Niebo w rzucie równoprostokątnym: zenit u góry obrazu, horyzont w połowie, słońce i chmury.
    static let sky: CGImage = image(width: 1024, height: 512) { g in
        let space = CGColorSpaceCreateDeviceRGB()
        let colors = [
            UIColor(red: 0.42, green: 0.45, blue: 0.42, alpha: 1).cgColor, // ziemia (dół obrazu)
            UIColor(red: 0.74, green: 0.80, blue: 0.84, alpha: 1).cgColor,
            UIColor(red: 0.86, green: 0.91, blue: 0.97, alpha: 1).cgColor, // horyzont
            UIColor(red: 0.52, green: 0.72, blue: 0.94, alpha: 1).cgColor,
            UIColor(red: 0.20, green: 0.42, blue: 0.80, alpha: 1).cgColor, // zenit (góra obrazu)
        ] as CFArray
        let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.47, 0.5, 0.62, 1])!
        g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: 512), options: [])
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<70 {
            let x = CGFloat.random(in: 0..<1024, using: &rng)
            let y = CGFloat.random(in: 262..<340, using: &rng)
            let w = CGFloat.random(in: 40..<140, using: &rng)
            g.setFillColor(UIColor(white: 1, alpha: .random(in: 0.12...0.3, using: &rng)).cgColor)
            g.fillEllipse(in: CGRect(x: x, y: y, width: w, height: w * 0.32))
        }
        let sun = CGPoint(x: 220, y: 400)
        let glow = CGGradient(colorsSpace: space, colors: [
            UIColor(red: 1, green: 0.98, blue: 0.9, alpha: 1).cgColor,
            UIColor(red: 1, green: 0.95, blue: 0.8, alpha: 0).cgColor,
        ] as CFArray, locations: [0, 1])!
        g.drawRadialGradient(glow, startCenter: sun, startRadius: 6, endCenter: sun, endRadius: 90, options: [])
    }

    /// Podłoże w kolorze krainy (trawa, piasek, śnieg…): ziarnista faktura w odcieniach `color`.
    static func ground(_ color: UIColor) -> PhysicallyBasedMaterial {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let img = image(width: 256, height: 256) { ctx in
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<3000 {
                let k = CGFloat.random(in: 0.85...1.15, using: &rng)
                ctx.setFillColor(UIColor(red: min(1, r * k), green: min(1, g * k), blue: min(1, b * k), alpha: 0.7).cgColor)
                ctx.fill(CGRect(x: .random(in: 0..<256, using: &rng), y: .random(in: 0..<256, using: &rng), width: 3, height: 3))
            }
        }
        return tiled(img, roughness: 1)
    }
    static let roadSurfaceMaterial = tiled(roadSurface, roughness: 0.82)

    /// Asfalt PBR: kolor, normalne (drobne kamyki łapią światło) i chropowatość — tekstury z ScenePreloader.
    /// Jezdnia z shaderem `roadSurface` (Ground.metal): zdjęcie asfaltu + plamy, ślady kół, kurz przy krawędziach.
    /// `nil`, gdy brak plików albo shadera — wtedy zwykły `photoAsphalt`.
    @MainActor static func roadAsphalt(halfWidth: Double, tile: Float = 4) -> CustomMaterial? {
        func tex(_ name: String) -> TextureResource? {
            Bundle.main.url(forResource: name, withExtension: "jpg").flatMap(SkyEnvironment.texture)
        }
        guard let color = tex("road-asphalt"), let normal = tex("road-asphalt-normal"), let rough = tex("road-asphalt-rough"),
              var m = SceneShaders.material("roadSurface")
        else { return nil }
        m.baseColor = .init(tint: UIColor(white: 0.92, alpha: 1), texture: .init(color))
        m.normal = .init(texture: .init(normal))
        m.roughness = .init(scale: 1, texture: .init(rough))
        SceneHaze.tag(&m)
        m.custom.value = [tile, Float(halfWidth), SceneHaze.current.packed, 0]
        return m
    }

    static func photoAsphalt() -> PhysicallyBasedMaterial? {
        func tex(_ name: String) -> TextureResource? {
            Bundle.main.url(forResource: name, withExtension: "jpg").flatMap(SkyEnvironment.texture)
        }
        guard let color = tex("road-asphalt") else { return nil }
        var m = tiled(color, roughness: 1)
        let s = MTLSamplerDescriptor()
        s.sAddressMode = .repeat
        s.tAddressMode = .repeat
        s.minFilter = .linear
        s.magFilter = .linear
        s.mipFilter = .linear
        s.maxAnisotropy = 16
        if let n = tex("road-asphalt-normal") { m.normal = .init(texture: .init(n, sampler: .init(s))) }
        if let r = tex("road-asphalt-rough") { m.roughness = .init(scale: 0.9, texture: .init(r, sampler: .init(s))) }
        m.baseColor.tint = UIColor(white: 0.92, alpha: 1)
        return m
    }
}
