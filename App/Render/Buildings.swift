import Metal
import RealityKit
import UIKit

/// Budynki z prawdziwych materiałów PBR (CC0 ambientCG i Poly Haven, katalog App/Buildings):
/// bryła w realnej skali (piętro 3,2 m), kamienny parter, gzyms nad parterem, fasada z oknami ułożona
/// całymi piętrami, attyka na dachu. Materiały są oświetlone (słońce + odbicia nieba), więc ściany
/// różnią się jasnością, a szyby odbijają niebo — w odróżnieniu od płaskich zdjęć-impostorów.
@MainActor
enum Buildings {
    struct Style {
        let name: String
        /// Ile pięter mieści jeden kafel tekstury (kafel jest kwadratowy).
        let floorsPerTile: Int
        let floors: ClosedRange<Int>
        var tile: Float { Float(floorsPerTile) * floorHeight }
    }

    static let floorHeight: Float = 3.2
    static let groundFloor: Float = 4.6

    /// Kamienice i bloki w pierwszej linii ulicy.
    static let street: [Style] = [
        Style(name: "brick-a", floorsPerTile: 6, floors: 4...7),
        Style(name: "brick-b", floorsPerTile: 5, floors: 4...6),
        Style(name: "concrete", floorsPerTile: 5, floors: 5...8),
    ]
    /// Wysokie biurowce w drugiej linii.
    static let towers: [Style] = [
        Style(name: "office", floorsPerTile: 8, floors: 10...18),
        Style(name: "glass", floorsPerTile: 10, floors: 14...26),
    ]

    static var available: Bool { Bundle.main.url(forResource: "facade-brick-a", withExtension: "jpg") != nil }

    /// Pliki tekstur do wczytania w tle (ScenePreloader).
    static var textureNames: [String] {
        (street + towers).flatMap { ["facade-\($0.name)", "facade-\($0.name)-normal", "facade-\($0.name)-rough", "facade-\($0.name)-metal"] }
            + ["plinth", "plinth-normal", "cornice", "cornice-normal"]
    }

    // MARK: - Składanie brył

    /// Zbiera ściany wszystkich budynków, po jednej siatce na materiał.
    @MainActor struct Batch {
        private(set) var parts: [String: MeshBuilder] = [:]
        private var roofs = MeshBuilder()

        /// Budynek na rzucie prostokąta: `p` — środek podstawy, `f` — kierunek do drogi (poziomy, jednostkowy).
        mutating func add(_ style: Style, floors: Int, at p: SIMD3<Float>, facing f: SIMD3<Float>, width: Float, depth: Float) {
            let r = SIMD3<Float>(f.z, 0, -f.x)
            let hw = width / 2, hd = depth / 2
            let base = p.y
            let plinthTop = base + Buildings.groundFloor
            let bodyTop = plinthTop + Float(floors) * Buildings.floorHeight
            // Parter z kamiennych płyt (kafel 2,4 m), lekko cofnięty — gzyms nad nim rzuca cień.
            box(&parts["plinth", default: MeshBuilder()], p, f, r, hw - 0.15, hd - 0.15, base, plinthTop, tile: 2.4, v0: base)
            // Gzym nad parterem i attyka — wystające pasy jasnego kamienia.
            box(&parts["cornice", default: MeshBuilder()], p, f, r, hw + 0.25, hd + 0.25, plinthTop - 0.1, plinthTop + 0.45, tile: 2, v0: plinthTop)
            box(&parts["cornice", default: MeshBuilder()], p, f, r, hw + 0.3, hd + 0.3, bodyTop, bodyTop + 0.9, tile: 2, v0: bodyTop)
            // Fasada: v liczone od góry parteru, więc kafel zawsze zaczyna się od pełnego piętra.
            box(&parts["facade-\(style.name)", default: MeshBuilder()], p, f, r, hw, hd, plinthTop + 0.45, bodyTop, tile: style.tile, v0: plinthTop)
            let top = bodyTop + 0.9
            let c = { (a: Float, b: Float) in p + f * a + r * b + SIMD3<Float>(0, top - base, 0) }
            roofs.quad(c(-hd, hw), c(-hd, -hw), c(hd, -hw), c(hd, hw))
        }

        /// Prostopadłościan bez dna i dachu; UV w metrach / `tile`, `v0` — wysokość, od której liczy się kafel.
        private func box(_ b: inout MeshBuilder, _ p: SIMD3<Float>, _ f: SIMD3<Float>, _ r: SIMD3<Float>,
                         _ hw: Float, _ hd: Float, _ y0: Float, _ y1: Float, tile: Float, v0: Float) {
            let lo = SIMD3<Float>(0, y0 - p.y, 0), hi = SIMD3<Float>(0, y1 - p.y, 0)
            let va = (y0 - v0) / tile, vb = (y1 - v0) / tile
            // Narożniki: fl — przód-lewo (patrząc z drogi), itd.
            let fl = p + f * hd + r * hw, fr = p + f * hd - r * hw
            let bl = p - f * hd + r * hw, br = p - f * hd - r * hw
            // Każda ściana od lewego do prawego narożnika, patrząc z zewnątrz.
            for (a, c, len) in [(fr, fl, 2 * hw), (fl, bl, 2 * hd), (bl, br, 2 * hw), (br, fr, 2 * hd)] {
                let u = len / tile
                b.quad(a + lo, c + lo, c + hi, a + hi, uv: [[0, va], [u, va], [u, vb], [0, vb]])
            }
        }

        func build() -> Entity {
            let root = Entity()
            for (name, b) in parts where !b.isEmpty {
                guard let mesh = try? b.mesh(name: name) else { continue }
                let material: any Material = (name == "plinth" ? Buildings.shopfronts() : nil) ?? Buildings.material(name)
                root.addChild(ModelEntity(mesh: mesh, materials: [material]))
            }
            if !roofs.isEmpty, let mesh = try? roofs.mesh(name: "roofs") {
                root.addChild(ModelEntity(mesh: mesh, materials: [Materials.matte(UIColor(white: 0.24, alpha: 1))]))
            }
            return root
        }
    }

    // MARK: - Materiały

    private static var cache: [String: PhysicallyBasedMaterial] = [:]

    static func material(_ name: String) -> PhysicallyBasedMaterial {
        if let m = cache[name] { return m }
        func tex(_ suffix: String) -> TextureResource? {
            Bundle.main.url(forResource: name + suffix, withExtension: "jpg").flatMap(SkyEnvironment.texture)
        }
        let sampler = repeatSampler
        var m = PhysicallyBasedMaterial()
        if let c = tex("") { m.baseColor = .init(tint: .white, texture: .init(c, sampler: sampler)) }
        if let n = tex("-normal") { m.normal = .init(texture: .init(n, sampler: sampler)) }
        if let r = tex("-rough") {
            m.roughness = .init(scale: 1, texture: .init(r, sampler: sampler))
        } else {
            m.roughness = 0.85
        }
        if let mt = tex("-metal") {
            m.metallic = .init(scale: 1, texture: .init(mt, sampler: sampler))
        }
        cache[name] = m
        return m
    }

    /// Parter z witrynami sklepów (shader `plinthSurface`, Ground.metal) na zdjęciu kamiennych płyt;
    /// `nil` bez plików albo shadera — wtedy pełna ściana z płyt.
    static func shopfronts() -> CustomMaterial? {
        func tex(_ name: String) -> TextureResource? {
            Bundle.main.url(forResource: name, withExtension: "jpg").flatMap(SkyEnvironment.texture)
        }
        guard let color = tex("plinth"), let normal = tex("plinth-normal"),
              var m = SceneShaders.material("plinthSurface")
        else { return nil }
        m.baseColor = .init(tint: .white, texture: .init(color))
        m.normal = .init(texture: .init(normal))
        SceneHaze.tag(&m)
        m.custom.value = [SceneHaze.current.packed, TrackBuilder.groundY, groundFloor, 0]
        return m
    }

    static func purge() { cache.removeAll() }

    private static let repeatSampler: MaterialParameters.Texture.Sampler = {
        let s = MTLSamplerDescriptor()
        s.sAddressMode = .repeat
        s.tAddressMode = .repeat
        s.minFilter = .linear
        s.magFilter = .linear
        s.mipFilter = .linear
        s.maxAnisotropy = 16
        return .init(s)
    }()
}
