import RealityKit
import UIKit

/// Podest w garażu i menu, jak obrotnica w salonie samochodowym: nieruchomy cokół ze ściętą krawędzią,
/// pasem LED i poświatą na podłodze, a na nim obracająca się tarcza z grafitowego, szczotkowanego metalu
/// z miękkim cieniem pod autem. Górna powierzchnia tarczy leży na y = 0 (tam stoją koła).
@MainActor
enum Podium {
    static let radius: Float = 4.35
    private static let accent = UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)

    /// `base` stoi w miejscu, `top` obraca się razem z autem, `shadow` to cień auta (ukryty, gdy auta brak).
    static func make() -> (base: Entity, top: Entity, shadow: Entity) {
        let base = Entity()
        let top = Entity()
        let r = radius

        // Cokół: od podłogi lekko zwężający się w górę, ścięta, chromowana krawędź pod tarczą.
        let graphite = metal(UIColor(red: 0.11, green: 0.115, blue: 0.13, alpha: 1), roughness: 0.42)
        let chrome = metal(UIColor(white: 0.85, alpha: 1), roughness: 0.12)
        add(lathe([(r + 0.30, -0.42), (r + 0.25, -0.20)]), graphite, to: base)
        add(lathe([(r + 0.25, -0.14), (r + 0.22, -0.06)]), graphite, to: base)
        add(lathe([(r + 0.22, -0.06), (r + 0.12, -0.005), (r + 0.02, -0.005)]), chrome, to: base)
        // Pas LED na boku cokołu i cienka świecąca linia między cokołem a tarczą.
        add(lathe([(r + 0.25, -0.20), (r + 0.25, -0.14)]), Materials.glow(accent, intensity: 3.5), to: base)
        add(lathe([(r + 0.02, -0.004), (r - 0.02, -0.004)]), Materials.glow(accent, intensity: 2), to: base)

        // Poświata LED na podłodze wokół podestu.
        if let glow = decal(size: 22, color: accent, opacity: 0.18, mask: ringGlowMask) {
            glow.position.y = -0.41
            base.addChild(glow)
        }

        // Tarcza: szczotkowany metal z frezowanymi rowkami; bok tarczy chromowany.
        var plate = PhysicallyBasedMaterial()
        if let tex = try? Materials.texture(brushedPlate) {
            plate.baseColor = .init(tint: .white, texture: .init(tex))
        }
        plate.metallic = 0.85
        plate.roughness = 0.32
        plate.clearcoat = 0.5
        plate.clearcoatRoughness = 0.08
        add(disc(radius: r, y: 0), plate, to: top)
        add(lathe([(r, 0), (r, -0.004)]), chrome, to: top)

        // Miękki cień pod autem (obraca się razem z nim).
        let shadow = decal(width: 2.8, depth: 5.6, color: .black, opacity: 0.75, mask: shadowMask) ?? Entity()
        shadow.position.y = 0.006
        top.addChild(shadow)
        return (base, top, shadow)
    }

    // MARK: - Bryły

    /// Bryła obrotowa z profilu (promień, wysokość), od zewnątrz do środka albo z góry na dół.
    private static func lathe(_ profile: [(Float, Float)], segments: Int = 160) -> MeshBuilder {
        var b = MeshBuilder()
        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * 2 * .pi, a1 = Float(i + 1) / Float(segments) * 2 * .pi
            for k in 0..<(profile.count - 1) {
                let (r0, y0) = profile[k], (r1, y1) = profile[k + 1]
                let p00 = SIMD3<Float>(cos(a0) * r0, y0, sin(a0) * r0), p01 = SIMD3<Float>(cos(a1) * r0, y0, sin(a1) * r0)
                let p10 = SIMD3<Float>(cos(a0) * r1, y1, sin(a0) * r1), p11 = SIMD3<Float>(cos(a1) * r1, y1, sin(a1) * r1)
                b.quad(p10, p11, p01, p00, doubleSided: true)
            }
        }
        return b
    }

    /// Płaski krąg z UV od 0 do 1 na całej średnicy (pod teksturę tarczy).
    private static func disc(radius r: Float, y: Float, segments: Int = 160) -> MeshBuilder {
        var b = MeshBuilder()
        func uv(_ p: SIMD3<Float>) -> SIMD2<Float> { [p.x / (2 * r) + 0.5, p.z / (2 * r) + 0.5] }
        let c = SIMD3<Float>(0, y, 0)
        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * 2 * .pi, a1 = Float(i + 1) / Float(segments) * 2 * .pi
            let p0 = SIMD3<Float>(cos(a0) * r, y, sin(a0) * r), p1 = SIMD3<Float>(cos(a1) * r, y, sin(a1) * r)
            // Trójkąt jako czworokąt ze zdublowanym środkiem, widoczny od góry.
            b.quad(c, p1, p0, c, uv: [uv(c), uv(p1), uv(p0), uv(c)])
        }
        return b
    }

    private static func add(_ b: MeshBuilder, _ material: any Material, to parent: Entity) {
        guard let mesh = try? b.mesh(name: "podium") else { return }
        parent.addChild(ModelEntity(mesh: mesh, materials: [material]))
    }

    private static func metal(_ color: UIColor, roughness: Float) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.metallic = 1.0
        m.roughness = .init(floatLiteral: roughness)
        return m
    }

    // MARK: - Tekstury

    /// Płaski prostokąt bez cieniowania w kolorze `color`, przezroczystość z maski (biel = widoczne).
    private static func decal(width: Float, depth: Float, color: UIColor, opacity: Float, mask: CGImage) -> ModelEntity? {
        guard let tex = try? TextureResource(image: mask, options: .init(semantic: .raw, mipmapsMode: .allocateAndGenerateAll))
        else { return nil }
        var m = UnlitMaterial(color: color)
        m.blending = .transparent(opacity: .init(scale: opacity, texture: .init(tex)))
        return ModelEntity(mesh: .generatePlane(width: width, depth: depth), materials: [m])
    }

    private static func decal(size: Float, color: UIColor, opacity: Float, mask: CGImage) -> ModelEntity? {
        decal(width: size, depth: size, color: color, opacity: opacity, mask: mask)
    }

    private static func grayImage(_ size: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        draw(ctx)
        return ctx.makeImage()!
    }

    /// Pierścień światła: najjaśniej tuż przy cokole, wygasa na zewnątrz (pod cokołem ciemno).
    private static let ringGlowMask: CGImage = grayImage(512) { ctx in
        let c = CGPoint(x: 256, y: 256)
        let inner = CGFloat((radius + 0.2) / 11) * 256 // promień cokołu w skali obrazka (22 m → 512 px)
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                  colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.2, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray,
                                  locations: [0, 0.12, 0.5])!
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: inner, endCenter: c, endRadius: 256, options: [])
    }

    /// Miękki, eliptyczny cień auta (obrazek kwadratowy, rozciągnięty na prostokąt pod autem).
    private static let shadowMask: CGImage = grayImage(256) { ctx in
        let c = CGPoint(x: 128, y: 128)
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                  colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.7, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray,
                                  locations: [0, 0.45, 1])!
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: 128, options: [])
    }

    /// Grafitowa tarcza: koncentryczne „szczotkowanie”, trzy frezowane rowki i cienka złota linia przy brzegu.
    private static let brushedPlate: CGImage = Materials.image(width: 1024, height: 1024) { ctx in
        let c = CGPoint(x: 512, y: 512)
        ctx.setFillColor(UIColor(red: 0.16, green: 0.165, blue: 0.18, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        var rng = SystemRandomNumberGenerator()
        // Drobne koncentryczne rysy szczotkowanego metalu.
        var r: CGFloat = 4
        while r < 512 {
            let v = CGFloat.random(in: 0.1...0.26, using: &rng)
            ctx.setStrokeColor(UIColor(white: v, alpha: 0.5).cgColor)
            ctx.setLineWidth(CGFloat.random(in: 0.6...1.4, using: &rng))
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            r += CGFloat.random(in: 1.2...2.6, using: &rng)
        }
        // Frezowane rowki: ciemna linia z jasnym brzegiem.
        for f: CGFloat in [0.36, 0.66, 0.9] {
            let rr = 512 * f
            ctx.setStrokeColor(UIColor(white: 0.05, alpha: 1).cgColor)
            ctx.setLineWidth(5)
            ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
            ctx.setStrokeColor(UIColor(white: 0.45, alpha: 0.8).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: c.x - rr - 3.5, y: c.y - rr - 3.5, width: 2 * rr + 7, height: 2 * rr + 7))
        }
        // Złota linia przy krawędzi tarczy.
        let edge: CGFloat = 512 * 0.965
        ctx.setStrokeColor(UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1).cgColor)
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: CGRect(x: c.x - edge, y: c.y - edge, width: 2 * edge, height: 2 * edge))
    }
}
