import RaceCore
import RealityKit
import Metal
import UIKit

/// Impostor: zdjęcie obiektu z przodu i z boku (przezroczyste tło), wyrenderowane wcześniej z modelu 3D
/// (tools/render-impostors.py, tools/make-impostors.swift). Gry mobilne tak robią średni plan:
/// drzewo to dwie skrzyżowane płaszczyzny, budynek to prostopadłościan obłożony zdjęciami fasad.
struct ImpostorDef: Decodable {
    let name: String
    let kind: String
    let regions: [String]
    /// Zakres wysokości w grze (m).
    let height: [Double]
    let max: Int?
    /// Wymiary modelu: szerokość (X), wysokość (Y), głębokość (Z) — w jednostkach pliku, liczą się proporcje.
    let size: [Double]
    let front: String
    let side: String
}

struct Impostor {
    let def: ImpostorDef
    let base: URL
    var front: URL { base.appendingPathComponent(def.front) }
    var side: URL { base.appendingPathComponent(def.side) }

    func randomHeight(_ rng: SeededRandom) -> Double {
        let lo = def.height.first ?? 10, hi = def.height.last ?? lo
        return lo + (hi - lo) * rng.next()
    }
}

@MainActor
final class ImpostorLibrary {
    static let shared = ImpostorLibrary()

    /// Drzewa CC0 w paczce (App/Impostors) i fasady z modeli lokalnych (LocalModels → Models/Realistic).
    private(set) lazy var all: [Impostor] = {
        let bundle = Bundle.main.bundleURL
        return [bundle.appendingPathComponent("Impostors"), bundle.appendingPathComponent("Models/Realistic")]
            .flatMap(Self.load)
    }()

    private static func load(_ base: URL) -> [Impostor] {
        guard let data = try? Data(contentsOf: base.appendingPathComponent("impostors.json")),
              let defs = try? JSONDecoder().decode([ImpostorDef].self, from: data) else { return [] }
        return defs.map { Impostor(def: $0, base: base) }
            .filter { FileManager.default.fileExists(atPath: $0.front.path) && $0.def.size.count == 3 }
    }

    func items(_ kind: String, region: Region) -> [Impostor] {
        let key = LocalAssets.regionKey(region)
        return all.filter { $0.def.kind == kind && $0.def.regions.contains(key) }
    }

    /// Czy są jakiekolwiek impostory danego rodzaju (wtedy krainy bez nich zostają puste zamiast kanciastych modeli).
    func has(_ kind: String) -> Bool { all.contains { $0.def.kind == kind } }

    private var materials: [URL: UnlitMaterial] = [:]

    /// Zwalnia tekstury poprzedniej krainy (wołane przed budową trasy).
    func purge() { materials.removeAll() }

    /// Mipmapy z filtrowaniem anizotropowym — fasady i drzewa oglądane pod kątem zostają ostre.
    private static let sampler: MaterialParameters.Texture.Sampler = {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear
        d.magFilter = .linear
        d.mipFilter = .linear
        d.maxAnisotropy = 8
        return .init(d)
    }()

    /// Materiał bez cieniowania (światło jest już w zdjęciu) z wycinaniem po kanale alfa — bez sortowania przezroczystości.
    func material(_ url: URL) -> UnlitMaterial? {
        if let m = materials[url] { return m }
        guard let image = UIImage(contentsOfFile: url.path)?.cgImage,
              let tex = try? TextureResource(image: image, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll)),
              let mask = Self.alphaMask(image),
              let opacity = try? TextureResource(image: mask, options: .init(semantic: .raw, mipmapsMode: .allocateAndGenerateAll))
        else { return nil }
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(tex, sampler: Self.sampler))
        // Tekstura nieprzezroczystości czyta pierwszy kanał (czerwony), nie alfę — maskę robimy osobno.
        m.blending = .transparent(opacity: .init(scale: 1, texture: .init(opacity, sampler: Self.sampler)))
        m.opacityThreshold = 0.5
        materials[url] = m
        return m
    }

    /// Kanał alfa obrazu jako obraz w odcieniach szarości (białe = widoczne).
    private static func alphaMask(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let provider = CGDataProvider(data: Data(bytes: data, count: w * h) as CFData)
        return provider.flatMap {
            CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                    provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }
}

/// Zbiera czworokąty impostorów pogrupowane po teksturze i składa z nich po jednej siatce na teksturę.
@MainActor
struct ImpostorBatch {
    private var builders: [URL: MeshBuilder] = [:]
    private var roofs = MeshBuilder()

    /// Drzewo/krzak: dwie skrzyżowane płaszczyzny — przód w poprzek drogi (widać go, jadąc), bok wzdłuż drogi.
    mutating func plant(_ item: Impostor, height: Double, at p: SIMD3<Float>, heading: Double) {
        let s = item.def.size
        let k = Float(height / s[1])
        let h = Float(height)
        let wf = Float(s[0]) * k / 2, ws = Float(s[2]) * k / 2
        let along = SIMD3<Float>(Float(sin(heading)), 0, Float(cos(heading)))
        let across = SIMD3<Float>(along.z, 0, -along.x)
        let up = SIMD3<Float>(0, h, 0)
        builders[item.front, default: MeshBuilder()].quad(p - across * wf, p + across * wf, p + across * wf + up, p - across * wf + up,
                                                         uv: [[0, 0], [1, 0], [1, 1], [0, 1]], doubleSided: true)
        builders[item.side, default: MeshBuilder()].quad(p + along * ws, p - along * ws, p - along * ws + up, p + along * ws + up,
                                                        uv: [[0, 0], [1, 0], [1, 1], [0, 1]], doubleSided: true)
    }

    /// Budynek: prostopadłościan, fasada (szerszy widok modelu) od strony drogi i z tyłu, boki z węższego widoku
    /// albo — gdy model to sama ściana — z tej samej fasady. `facing` to kierunek od budynku do drogi.
    /// Szerokość fasady i głębokość bryły (m): z widoku z boku, a gdy model to sama ściana — ok. połowa szerokości.
    static func buildingSize(_ item: Impostor, height: Double) -> (width: Float, depth: Float) {
        let s = item.def.size
        let wideSize = Float(Swift.max(s[0], s[2])), narrowSize = Float(Swift.min(s[0], s[2]))
        let k = Float(height) / Float(s[1])
        let width = wideSize * k
        return (width, narrowSize / wideSize > 0.3 ? narrowSize * k : Swift.max(8, width * 0.55))
    }

    mutating func building(_ item: Impostor, height: Double, at p: SIMD3<Float>, facing: SIMD3<Float>) {
        let s = item.def.size
        let frontWide = s[0] >= s[2]
        let facade = frontWide ? item.front : item.side
        let realSides = Float(Swift.min(s[0], s[2]) / Swift.max(s[0], s[2])) > 0.3
        let (width, depth) = Self.buildingSize(item, height: height)
        let sideTex = realSides ? (frontWide ? item.side : item.front) : facade
        let h = Float(height)
        let f = simd_normalize(facing)
        let r = SIMD3<Float>(f.z, 0, -f.x) // w prawo, patrząc od drogi na fasadę
        let up = SIMD3<Float>(0, h, 0)
        let hw = width / 2, hd = depth / 2
        // Narożniki podstawy.
        let fl = p + f * hd + r * hw, fr = p + f * hd - r * hw
        let bl = p - f * hd + r * hw, br = p - f * hd - r * hw
        // Wierzchołki przeciwnie do wskazówek zegara, patrząc z zewnątrz (lewy dolny róg pierwszy).
        builders[facade, default: MeshBuilder()].quad(fr, fl, fl + up, fr + up) // front (od drogi)
        builders[facade, default: MeshBuilder()].quad(bl, br, br + up, bl + up) // tył
        builders[sideTex, default: MeshBuilder()].quad(br, fr, fr + up, br + up) // bok
        builders[sideTex, default: MeshBuilder()].quad(fl, bl, bl + up, fl + up) // bok
        roofs.quad(bl + up, br + up, fr + up, fl + up)
    }

    func build() -> Entity {
        let root = Entity()
        for (url, b) in builders where !b.isEmpty {
            guard let m = ImpostorLibrary.shared.material(url), let mesh = try? b.mesh(name: url.lastPathComponent) else { continue }
            root.addChild(ModelEntity(mesh: mesh, materials: [m]))
        }
        if !roofs.isEmpty, let mesh = try? roofs.mesh(name: "roofs") {
            root.addChild(ModelEntity(mesh: mesh, materials: [Materials.matte(UIColor(white: 0.28, alpha: 1))]))
        }
        return root
    }
}

/// Materiał gruntu z shaderem `groundSurface` (Ground.metal): tekstura w układzie świata i zanikanie w oddali.
@MainActor
struct GroundMaterial {
    private(set) var material: CustomMaterial
    /// Rozmiar kafla tekstury (m) i odległość, od której grunt zaczyna znikać (m).
    static let tile: Float = 5, fadeStart: Float = 170

    static func make(_ image: CGImage) -> GroundMaterial? {
        guard let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary(),
              let tex = try? Materials.texture(image),
              var m = try? CustomMaterial(surfaceShader: .init(named: "groundSurface", in: library), lightingModel: .lit)
        else { return nil }
        m.baseColor = .init(tint: .white, texture: .init(tex))
        m.blending = .transparent(opacity: 1.0)
        m.custom.value = [0, 0, tile, fadeStart]
        return GroundMaterial(material: m)
    }

    /// Środek zanikania podąża za kamerą.
    mutating func follow(_ camera: SIMD3<Float>, on entity: ModelEntity) {
        material.custom.value = [camera.x, camera.z, Self.tile, Self.fadeStart]
        entity.model?.materials = [material]
    }
}
