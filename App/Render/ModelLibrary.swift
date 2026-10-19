import CoreGraphics
import Metal
import RaceCore
import RealityKit
import UIKit

/// Modele OBJ z katalogu `Models` w paczce aplikacji (CC0, Kenney): wczytanie, materiały, tekstury
/// i gotowe wzorce do klonowania. Brak pliku = nil, a wołający wraca do modelu generowanego w kodzie.
@MainActor
final class ModelLibrary {
    static let shared = ModelLibrary()

    struct Loaded: Sendable {
        let model: ObjModel
        let materials: [String: ObjMaterial]
        let folder: URL
    }

    private let root = Bundle.main.url(forResource: "Models", withExtension: nil)
    private var loaded: [String: Loaded] = [:]
    private var images: [URL: CGImage] = [:]
    private var textures: [URL: TextureResource] = [:]
    private var templates: [String: Entity] = [:]

    /// Przetwarza wszystkie modele OBJ w tle (poza wątkiem głównym), żeby pierwszy wyścig nie czekał.
    func prefetch() async {
        guard let root else { return }
        let fm = FileManager.default
        var paths: [String] = []
        for dir in ["Cars", "City", "Track"] {
            let files = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)) ?? []
            paths += files.filter { $0.hasSuffix(".obj") }.map { "\(dir)/" + $0.dropLast(4) }
        }
        let todo = paths.filter { loaded[$0] == nil }
        let parsed = await Task.detached(priority: .utility) { () -> [(String, Loaded)] in
            todo.compactMap { path in Self.parse(path: path, root: root).map { (path, $0) } }
        }.value
        for (path, l) in parsed where loaded[path] == nil { loaded[path] = l }
        debugLog("modele OBJ: \(parsed.count) przetworzonych w tle")
    }

    nonisolated private static func parse(path: String, root: URL) -> Loaded? {
        let url = root.appendingPathComponent(path + ".obj")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let model = ObjModel.parse(text)
        let folder = url.deletingLastPathComponent()
        var mats: [String: ObjMaterial] = [:]
        if let lib = model.materialLibrary,
           let mtl = try? String(contentsOf: folder.appendingPathComponent(lib), encoding: .utf8) {
            mats = ObjModel.parseMaterials(mtl)
        }
        return Loaded(model: model, materials: mats, folder: folder)
    }

    /// `path` bez rozszerzenia, np. "Cars/sedan-sports".
    func load(_ path: String) -> Loaded? {
        if let l = loaded[path] { return l }
        guard let root, let l = Self.parse(path: path, root: root) else { return nil }
        loaded[path] = l
        return l
    }

    func image(_ url: URL) -> CGImage? {
        if let i = images[url] { return i }
        let i = UIImage(contentsOfFile: url.path)?.cgImage
        images[url] = i
        return i
    }

    /// Tekstura palety: bez mipmap i z zaciśniętymi krawędziami, żeby sąsiednie pola kolorów się nie mieszały.
    func paletteTexture(_ image: CGImage) -> TextureResource? {
        try? TextureResource(image: image, options: .init(semantic: .color, mipmapsMode: .none))
    }

    func material(_ m: ObjMaterial, folder: URL) -> PhysicallyBasedMaterial {
        var out = PhysicallyBasedMaterial()
        out.roughness = 0.7
        out.metallic = 0.0
        if let tex = m.texture {
            let url = folder.appendingPathComponent(tex)
            if textures[url] == nil, let img = image(url) { textures[url] = paletteTexture(img) }
            if let t = textures[url] {
                out.baseColor = .init(tint: .white, texture: .init(t, sampler: Self.paletteSampler))
                return out
            }
        }
        out.baseColor = .init(tint: UIColor(red: CGFloat(m.diffuse.x), green: CGFloat(m.diffuse.y), blue: CGFloat(m.diffuse.z), alpha: 1))
        return out
    }

    static let paletteSampler: MaterialParameters.Texture.Sampler = {
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        return .init(s)
    }()

    /// Siatka z części modelu; `offset` przesuwa wierzchołki (np. środek koła do zera, żeby kręciło się w miejscu).
    func mesh(_ part: ObjPart, offset: SIMD3<Float> = .zero) -> MeshResource? {
        var desc = MeshDescriptor(name: part.material)
        desc.positions = MeshBuffers.Positions(part.positions.map { $0 - offset })
        if !part.normals.isEmpty { desc.normals = MeshBuffers.Normals(part.normals) }
        if !part.uvs.isEmpty { desc.textureCoordinates = MeshBuffers.TextureCoordinates(part.uvs) }
        desc.primitives = .triangles(part.indices)
        return try? MeshResource.generate(from: [desc])
    }

    /// Model do ustawienia na scenie: wyśrodkowany w X/Z, stoi na y = 0, przeskalowany jednolicie o `scale`.
    /// Wzorzec jest budowany raz; każde wywołanie zwraca klon, który współdzieli siatki i materiały.
    func prop(_ path: String, scale: Float = 1) -> Entity? {
        if let t = templates[path] { return Self.scaled(t.clone(recursive: true), scale) }
        guard let l = load(path) else { return nil }
        let b = l.model.bounds
        let center = SIMD3<Float>((b.min.x + b.max.x) / 2, b.min.y, (b.min.z + b.max.z) / 2)
        let template = Entity()
        for g in l.model.groups {
            for p in g.parts {
                guard let mesh = mesh(p, offset: center) else { continue }
                template.addChild(ModelEntity(mesh: mesh, materials: [material(l.materials[p.material] ?? ObjMaterial(), folder: l.folder)]))
            }
        }
        templates[path] = template
        return Self.scaled(template.clone(recursive: true), scale)
    }

    /// Rozmiar modelu po wyśrodkowaniu (szerokość X, wysokość Y, głębokość Z) w jednostkach pliku.
    func size(_ path: String) -> SIMD3<Float>? {
        guard let b = load(path)?.model.bounds else { return nil }
        return b.max - b.min
    }

    private static func scaled(_ e: Entity, _ s: Float) -> Entity {
        e.scale = [s, s, s]
        return e
    }

    /// Paleta z przemalowanym polem lakieru. Zachowuje cieniowanie pola (gradient), zmienia tylko barwę.
    func paintedPalette(_ base: CGImage, row: Int, column: Int, color: UIColor) -> CGImage {
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return base }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        // W pamięci bufora wiersz 0 to góra obrazu, tak jak w polu palety.
        let cw = w / 8, ch = h / 4
        let x0 = column * cw, y0 = row * ch
        func lum(_ i: Int) -> Double { 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2]) }
        var sum = 0.0
        for y in y0..<(y0 + ch) { for x in x0..<(x0 + cw) { sum += lum((y * w + x) * 4) } }
        let avg = max(1, sum / Double(cw * ch))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        for y in y0..<(y0 + ch) {
            for x in x0..<(x0 + cw) {
                let i = (y * w + x) * 4
                let k = min(1.5, max(0.5, lum(i) / avg))
                px[i] = UInt8(min(255, Double(r) * 255 * k))
                px[i + 1] = UInt8(min(255, Double(g) * 255 * k))
                px[i + 2] = UInt8(min(255, Double(b) * 255 * k))
            }
        }
        return ctx.makeImage() ?? base
    }
}
