import CoreGraphics
import RealityKit
import UIKit

/// Butla nitro na trasie: jak prawdziwa butla podtlenku azotu — walec z zaokrąglonym dnem, ramieniem
/// i szyjką, na szyjce zawór z pokrętłem i króćcem, metalowe opaski i naklejka. Jedna gęsta siatka
/// (96 segmentów, fazowane krawędzie) z trzema materiałami: niebieski lakier metalik z bezbarwną powłoką
/// i drobną „skórką pomarańczy” (mapa normalnych), szczotkowany metal (anizotropia), naklejka.
/// Do tego delikatna poświata za butlą (płat zawsze zwrócony do kamery).
/// Razem dwie encje — tyle co dawna kapsuła z kulą, bo butli na trasie jest kilkadziesiąt.
/// Środek butli w zerze, wysokość ok. 1,3 m (jak dawna kapsuła).
@MainActor
enum NitroCanister {
    static func make() -> Entity {
        let e = Entity()
        if let body = bottle() { e.addChild(body) }
        if let glow = glow() { e.addChild(glow) }
        return e
    }

    // MARK: - Bryła obrotowa

    /// Siatka z brył obrotowych: profil (promień, wysokość) obracany wokół osi; normalne z profilu,
    /// więc zaokrąglenia są gładkie, a krawędzie (np. pokrętło) — ostre, gdy punkt profilu się powtarza.
    private struct Lathe {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        /// `profile` — od dołu do góry; `frame` przenosi bryłę (oś Y) w docelowe miejsce.
        /// `arc` — zakres kąta (rad): pełny obrót albo wycinek (naklejka).
        mutating func add(_ profile: [SIMD2<Float>], segments: Int = 96, frame: simd_float4x4 = matrix_identity_float4x4,
                          arc: ClosedRange<Float> = 0...(2 * .pi)) {
            // Normalne profilu: prostopadłe do stycznej (średnia sąsiednich odcinków).
            var pn: [SIMD2<Float>] = []
            for i in 0..<profile.count {
                let a = profile[max(0, i - 1)], b = profile[min(profile.count - 1, i + 1)]
                let t = simd_normalize(b - a)
                pn.append([t.y, -t.x])
            }
            var lengths: [Float] = [0]
            for i in 1..<profile.count { lengths.append(lengths[i - 1] + simd_distance(profile[i], profile[i - 1])) }
            let total = max(lengths.last!, 1e-6)
            let n3 = simd_float3x3(SIMD3(frame.columns.0.x, frame.columns.0.y, frame.columns.0.z),
                                   SIMD3(frame.columns.1.x, frame.columns.1.y, frame.columns.1.z),
                                   SIMD3(frame.columns.2.x, frame.columns.2.y, frame.columns.2.z))
            let base = UInt32(positions.count)
            for i in 0..<profile.count {
                for j in 0...segments {
                    let a = arc.lowerBound + Float(j) / Float(segments) * (arc.upperBound - arc.lowerBound)
                    let c = cos(a), s = sin(a)
                    let p = SIMD4<Float>(profile[i].x * c, profile[i].y, profile[i].x * s, 1)
                    let wp = frame * p
                    positions.append([wp.x, wp.y, wp.z])
                    let n = SIMD3<Float>(pn[i].x * c, pn[i].y, pn[i].x * s)
                    normals.append(simd_normalize(n3 * n))
                    // u maleje z kątem: patrząc z zewnątrz rośnie w prawo (naklejka nie jest lustrzana).
                    uvs.append([1 - Float(j) / Float(segments), lengths[i] / total])
                }
            }
            let ring = UInt32(segments + 1)
            for i in 0..<(profile.count - 1) {
                for j in 0..<UInt32(segments) {
                    let a = base + UInt32(i) * ring + j, b = a + 1
                    let c = a + ring, d = c + 1
                    // Przeciwnie do wskazówek zegara patrząc z zewnątrz.
                    indices += [a, c, b, b, c, d]
                }
            }
        }

        func descriptor(_ name: String, material: UInt32) -> MeshDescriptor {
            var d = MeshDescriptor(name: name)
            d.positions = MeshBuffers.Positions(positions)
            d.normals = MeshBuffers.Normals(normals)
            // Styczne wzdłuż obwodu (kierunek u) — do mapy normalnych lakieru i anizotropii metalu.
            d[MeshBuffers.tangents] = MeshBuffers.Tangents(zip(positions, normals).map { p, n in
                let t = simd_cross([0, 1, 0], n)
                return simd_length(t) > 1e-4 ? simd_normalize(t) : [1, 0, 0]
            })
            d.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
            d.primitives = .triangles(indices)
            d.materials = .allFaces(material)
            return d
        }
    }

    /// Ćwiartka elipsy od (r0, y0) do (r1, y1) — zaokrąglone dno i ramię butli.
    private static func arc(from a: SIMD2<Float>, to b: SIMD2<Float>, bottom: Bool, steps: Int = 10) -> [SIMD2<Float>] {
        (0...steps).map { k in
            let t = Float(k) / Float(steps) * .pi / 2
            // Dno: od osi (r = 0) na zewnątrz; ramię: od pełnego promienia do szyjki.
            return bottom ? [b.x * sin(t), a.y + (b.y - a.y) * (1 - cos(t))]
                : [a.x + (b.x - a.x) * (1 - cos(t)), a.y + (b.y - a.y) * sin(t)]
        }
    }

    /// Zaokrąglona krawędź (fazka): ćwiartka okręgu o promieniu `r` w narożniku profilu.
    private static func fillet(corner c: SIMD2<Float>, from d0: SIMD2<Float>, to d1: SIMD2<Float>, r: Float, steps: Int = 4) -> [SIMD2<Float>] {
        // d0 — kierunek dochodzący do narożnika, d1 — wychodzący; punkty od c − d0·r do c + d1·r.
        let p0 = c - d0 * r, p1 = c + d1 * r
        return (0...steps).map { k in
            let t = Float(k) / Float(steps)
            // Krzywa Béziera 2. stopnia z narożnikiem jako punktem kontrolnym.
            return (1 - t) * (1 - t) * p0 + 2 * (1 - t) * t * c + t * t * p1
        }
    }

    private static func bottle() -> ModelEntity? {
        let R: Float = 0.25
        var paint = Lathe(), metal = Lathe(), label = Lathe()
        // Korpus: zaokrąglone dno, walec, ramię zwężające się do szyjki (gęsta siatka: 96 segmentów).
        var body = arc(from: [0, -0.62], to: [R, -0.47], bottom: true, steps: 16)
        body += [[R, 0.2]]
        body += arc(from: [R, 0.2], to: [0.075, 0.4], bottom: false, steps: 16).dropFirst()
        paint.add(body)
        // Szyjka i zawór (metal) z fazowanymi krawędziami: pierścień, korpus zaworu, pokrętło.
        var valve: [SIMD2<Float>] = [[0, 0.385], [0.078, 0.385]]
        valve += fillet(corner: [0.086, 0.392], from: [1, 0], to: [0, 1], r: 0.007)
        valve += fillet(corner: [0.086, 0.452], from: [0, 1], to: [-1, 0], r: 0.007)
        valve += [[0.062, 0.455]]
        valve += fillet(corner: [0.06, 0.552], from: [0, 1], to: [1, 0], r: 0.004)
        valve += fillet(corner: [0.072, 0.556], from: [1, 0], to: [0, 1], r: 0.004)
        valve += fillet(corner: [0.072, 0.6], from: [0, 1], to: [-1, 0], r: 0.004)
        valve += [[0.03, 0.605], [0.03, 0.628]]
        // Pokrętło: dysk z karbowaną krawędzią (fazki góra i dół).
        valve += fillet(corner: [0.132, 0.628], from: [1, 0], to: [0, 1], r: 0.008)
        valve += fillet(corner: [0.132, 0.662], from: [0, 1], to: [-1, 0], r: 0.008)
        valve += [[0.03, 0.664], [0.02, 0.672], [0, 0.672]]
        metal.add(valve, segments: 64)
        // Króciec wylotu z boku zaworu (oś wzdłuż X), z nakrętką.
        var outlet = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: [0, 0, 1]))
        outlet.columns.3 = [0.04, 0.515, 0, 1]
        var spout: [SIMD2<Float>] = [[0, 0], [0.026, 0], [0.026, 0.085]]
        spout += fillet(corner: [0.036, 0.088], from: [1, 0], to: [0, 1], r: 0.004)
        spout += fillet(corner: [0.036, 0.138], from: [0, 1], to: [-1, 0], r: 0.004)
        spout += [[0.014, 0.14], [0.014, 0.135], [0, 0.135]]
        metal.add(spout, segments: 32, frame: outlet)
        // Obręcze — metalowe opaski z zaokrąglonymi brzegami.
        for y: Float in [-0.34, 0.1] {
            var band: [SIMD2<Float>] = [[R - 0.002, y]]
            band += fillet(corner: [R + 0.007, y], from: [1, 0], to: [0, 1], r: 0.005)
            band += fillet(corner: [R + 0.007, y + 0.03], from: [0, 1], to: [-1, 0], r: 0.005)
            band += [[R - 0.002, y + 0.03]]
            metal.add(band)
        }
        // Naklejka między opaskami: wycinek walca tuż nad lakierem, z obu stron butli.
        for start: Float in [-0.95, -0.95 + .pi] {
            label.add([[R + 0.0015, -0.28], [R + 0.0015, 0.06]], segments: 32, arc: start...(start + 1.9))
        }

        var shell = PhysicallyBasedMaterial()
        shell.baseColor = .init(tint: UIColor(red: 0.04, green: 0.27, blue: 0.78, alpha: 1))
        shell.metallic = 0.55 // lakier metalik
        shell.roughness = 0.38
        shell.clearcoat = 1.0
        shell.clearcoatRoughness = 0.02
        if let n = Self.orangePeel { shell.normal = .init(texture: .init(n)) }
        // Bardzo lekkie świecenie: butla czytelna w cieniu, ale nie „neon”.
        shell.emissiveColor = .init(color: UIColor(red: 0.1, green: 0.4, blue: 1, alpha: 1))
        shell.emissiveIntensity = 0.12
        var steel = PhysicallyBasedMaterial()
        steel.baseColor = .init(tint: UIColor(white: 0.9, alpha: 1))
        steel.metallic = 1.0
        steel.roughness = 0.24
        // Szczotkowany metal: odblask rozciągnięty wzdłuż obwodu (anizotropia).
        steel.anisotropyLevel = 0.7
        steel.anisotropyAngle = 0.0
        var sticker = PhysicallyBasedMaterial()
        if let tex = Self.labelTexture {
            sticker.baseColor = .init(tint: .white, texture: .init(tex))
        }
        sticker.roughness = 0.25
        sticker.clearcoat = 0.6
        sticker.clearcoatRoughness = 0.08
        guard let mesh = try? MeshResource.generate(from: [paint.descriptor("nitro-body", material: 0),
                                                            metal.descriptor("nitro-valve", material: 1),
                                                            label.descriptor("nitro-label", material: 2)])
        else { return nil }
        let e = ModelEntity(mesh: mesh, materials: [shell, steel, sticker])
        // Lekko pochylona — wirując, pokazuje zawór i dno.
        e.orientation = simd_quatf(angle: 0.18, axis: [0, 0, 1])
        return e
    }

    /// „Skórka pomarańczy” lakieru: mapa normalnych z drobnego, łagodnego szumu (ledwo widoczne
    /// falowanie odbić, jak na prawdziwym lakierze).
    private static let orangePeel: TextureResource? = {
        let n = 256
        // Szum wartości na siatce 32×32, interpolowany gładko i zawijany (tekstura bez szwów).
        var rng = SystemRandomNumberGenerator()
        let g = 32
        let grid = (0..<(g * g)).map { _ in Float.random(in: 0...1, using: &rng) }
        func h(_ x: Float, _ y: Float) -> Float {
            let fx = x * Float(g), fy = y * Float(g)
            let x0 = Int(floor(fx)), y0 = Int(floor(fy))
            let tx = fx - Float(x0), ty = fy - Float(y0)
            func v(_ i: Int, _ j: Int) -> Float { grid[((j % g + g) % g) * g + ((i % g + g) % g)] }
            let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
            let a = v(x0, y0) + (v(x0 + 1, y0) - v(x0, y0)) * sx
            let b = v(x0, y0 + 1) + (v(x0 + 1, y0 + 1) - v(x0, y0 + 1)) * sx
            return a + (b - a) * sy
        }
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let e: Float = 1 / Float(n), k: Float = 0.9
        for y in 0..<n {
            for x in 0..<n {
                let u = Float(x) / Float(n), v = Float(y) / Float(n)
                let dx = (h(u + e, v) - h(u - e, v)) * k, dy = (h(u, v + e) - h(u, v - e)) * k
                let nrm = simd_normalize(SIMD3<Float>(-dx, -dy, 1))
                let i = (y * n + x) * 4
                px[i] = UInt8((nrm.x * 0.5 + 0.5) * 255)
                px[i + 1] = UInt8((nrm.y * 0.5 + 0.5) * 255)
                px[i + 2] = UInt8((nrm.z * 0.5 + 0.5) * 255)
                px[i + 3] = 255
            }
        }
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.data?.copyMemory(from: px, byteCount: px.count)
        guard let img = ctx.makeImage() else { return nil }
        return try? TextureResource(image: img, options: .init(semantic: .normal, mipmapsMode: .allocateAndGenerateAll))
    }()

    /// Naklejka: biała etykieta z czerwono-niebieskimi pasami i napisem „NITRO” (bez znaków towarowych).
    private static let labelTexture: TextureResource? = {
        let w = 512, h = 256
        let img = Materials.image(width: w, height: h) { g in
            g.setFillColor(UIColor(white: 0.95, alpha: 1).cgColor)
            g.fill(CGRect(x: 0, y: 0, width: w, height: h))
            g.setFillColor(UIColor(red: 0.85, green: 0.1, blue: 0.12, alpha: 1).cgColor)
            g.fill(CGRect(x: 0, y: 18, width: w, height: 22))
            g.fill(CGRect(x: 0, y: h - 40, width: w, height: 22))
            g.setFillColor(UIColor(red: 0.04, green: 0.2, blue: 0.6, alpha: 1).cgColor)
            g.fill(CGRect(x: 0, y: 44, width: w, height: 8))
            g.fill(CGRect(x: 0, y: h - 52, width: w, height: 8))
            UIGraphicsPushContext(g)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let title = NSAttributedString(string: "NITRO", attributes: [
                .font: UIFont.systemFont(ofSize: 104, weight: .black).withItalic(),
                .foregroundColor: UIColor(red: 0.04, green: 0.2, blue: 0.6, alpha: 1),
                .paragraphStyle: style,
            ])
            let sub = NSAttributedString(string: "N2O · 10 LB", attributes: [
                .font: UIFont.systemFont(ofSize: 30, weight: .bold),
                .foregroundColor: UIColor(white: 0.15, alpha: 1),
                .paragraphStyle: style,
            ])
            // Kontekst z `Materials.image` ma początek u dołu — odwracamy, żeby tekst nie był do góry nogami.
            g.saveGState()
            g.translateBy(x: 0, y: CGFloat(h))
            g.scaleBy(x: 1, y: -1)
            title.draw(in: CGRect(x: 0, y: 62, width: w, height: 120))
            sub.draw(in: CGRect(x: 0, y: 172, width: w, height: 40))
            g.restoreGState()
            UIGraphicsPopContext()
        }
        return try? TextureResource(image: img, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
    }()

    /// Delikatna poświata: miękki niebieski krąg za butlą, zawsze zwrócony do kamery.
    private static func glow() -> ModelEntity? {
        let n = 64
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        var px = [UInt8](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let dx = (Float(x) + 0.5) / Float(n) * 2 - 1, dy = (Float(y) + 0.5) / Float(n) * 2 - 1
                let r = sqrt(dx * dx + dy * dy)
                let v = max(0, 1 - r)
                px[y * n + x] = UInt8(min(255, v * v * v * 255))
            }
        }
        ctx.data?.copyMemory(from: px, byteCount: px.count)
        guard let img = ctx.makeImage(),
              let tex = try? TextureResource(image: img, options: .init(semantic: .raw, mipmapsMode: .allocateAndGenerateAll))
        else { return nil }
        var m = UnlitMaterial(color: UIColor(red: 0.35, green: 0.7, blue: 1, alpha: 1))
        m.blending = .transparent(opacity: .init(scale: 0.28, texture: .init(tex)))
        let e = ModelEntity(mesh: .generatePlane(width: 1.9, height: 1.9), materials: [m])
        e.components.set(BillboardComponent())
        return e
    }
}

private extension UIFont {
    func withItalic() -> UIFont {
        fontDescriptor.withSymbolicTraits([.traitItalic, .traitBold]).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}
