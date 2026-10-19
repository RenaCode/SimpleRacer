import CoreGraphics
import Metal
import RealityKit
import UIKit

/// Materiały i tekstury generowane w kodzie (bez plików graficznych).
@MainActor
enum Materials {
    /// Lakier metalik z warstwą bezbarwnego lakieru — odbija niebo.
    static func paint(_ color: UIColor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.metallic = 0.5
        m.roughness = 0.28
        m.clearcoat = 1.0
        m.clearcoatRoughness = 0.03
        return m
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
        var m = PhysicallyBasedMaterial()
        m.roughness = .init(floatLiteral: roughness)
        m.metallic = .init(floatLiteral: metallic)
        guard let tex = try? texture(image) else { return m }
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

    static let grass: CGImage = image(width: 256, height: 256) { g in
        g.setFillColor(UIColor(red: 0.3, green: 0.45, blue: 0.24, alpha: 1).cgColor)
        g.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<3000 {
            let k = CGFloat.random(in: 0.8...1.2, using: &rng)
            g.setFillColor(UIColor(red: 0.28 * k, green: 0.48 * k, blue: 0.22 * k, alpha: 0.7).cgColor)
            g.fill(CGRect(x: .random(in: 0..<256, using: &rng), y: .random(in: 0..<256, using: &rng), width: 3, height: 3))
        }
    }

    /// Elewacja z oknami; `floors`/`columns` dobiera się do proporcji budynku.
    static func facade(wall: UIColor, floors: Int, columns: Int) -> CGImage {
        image(width: columns * 32, height: floors * 32) { g in
            g.setFillColor(wall.cgColor)
            g.fill(CGRect(x: 0, y: 0, width: columns * 32, height: floors * 32))
            var rng = SystemRandomNumberGenerator()
            for f in 0..<floors {
                for c in 0..<columns {
                    let lit = Double.random(in: 0...1, using: &rng) < 0.12
                    let tone = CGFloat.random(in: 0.0...0.12, using: &rng)
                    g.setFillColor((lit ? UIColor(red: 0.95, green: 0.88, blue: 0.65, alpha: 1)
                                        : UIColor(red: 0.16 + tone, green: 0.24 + tone, blue: 0.34 + tone, alpha: 1)).cgColor)
                    g.fill(CGRect(x: c * 32 + 6, y: f * 32 + 7, width: 20, height: 19))
                }
            }
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

    static let grassMaterial = tiled(grass, roughness: 1)

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
}
