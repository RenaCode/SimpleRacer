import Metal
import RaceCore
import RealityKit
import UIKit

/// Mgła powietrzna liczona w shaderach otoczenia (grunt, jezdnia, mury, budynki, rekwizyty): dalekie obiekty 3D
/// bledną w stronę koloru horyzontu panoramy jak prawdziwe budynki i drzewa na zdjęciu za nimi.
///
/// Dawniej mgła była w obróbce obrazu (RacePostEffect) i liczyła odległość z tekstury głębi — ale RealityKit
/// (iOS 27, symulator) oddaje tam pustą głębię (z = 0 w każdym pikselu), więc mgły nie było nigdy.
/// W shaderze materiału odległość od kamery jest zawsze znana.
///
/// Parametry w shaderze: gęstość i zasięg spakowane w jedną liczbę `packed = zasięg (m, całkowity) + gęstość (0…1)`,
/// kolor w `emissiveColor` materiału; `packed = 0` — bez mgły (garaż).
struct SceneHaze {
    /// Kolor mgły (sRGB 0…1) — rozjaśniony i ochłodzony kolor pasa nad horyzontem panoramy.
    var color: SIMD3<Float>
    /// Największy udział mgły (0…1) i odległość (m), na której mgła osiąga ~63% tej wartości.
    var density: Float
    var scale: Float

    var packed: Float { scale.rounded() + min(max(density, 0), 0.999) }
    var uiColor: UIColor { UIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1) }

    /// Bez mgły (garaż, testy).
    static let none = SceneHaze(color: [1, 1, 1], density: 0, scale: 0)

    /// Mgła krainy: pustynia — suche, przejrzyste powietrze; las i śnieg — wilgotne, gęstsze.
    @MainActor static func of(_ region: Region) -> SceneHaze {
        let key = LocalAssets.regionKey(region)
        let fog: [String: (density: Float, scale: Float)] = [
            "city": (0.5, 300), "coast": (0.45, 380), "desert": (0.32, 480), "forest": (0.45, 260), "snow": (0.55, 230),
        ]
        let f = fog[key] ?? (0.4, 400)
        var haze = SceneHaze(color: PostFXSettings.forRegion(key).fogColor, density: f.density, scale: f.scale)
        #if DEBUG || FAMILY
        // `-haze d,s`: gęstość i zasięg do strojenia (i do kanarka: `-haze 0.99,20` musi zamglić cały kadr).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-haze"), i + 1 < args.count {
            let v = args[i + 1].split(separator: ",").compactMap { Float($0) }
            if v.count == 2 { haze.density = v[0]; haze.scale = v[1] }
        }
        if args.contains("-noHaze") { haze.density = 0 }
        #endif
        return haze
    }

    /// Mgła trasy, która się właśnie buduje — materiały otoczenia biorą ją stąd.
    @MainActor static var current = SceneHaze.none

    /// Materiał PBR przepisany na shader `hazeSurface` (te same tekstury i parametry + mgła).
    /// `nil` bez mgły albo bez shadera — wtedy zostaje zwykły materiał.
    @MainActor static func apply(_ pbr: PhysicallyBasedMaterial) -> (any Material)? {
        let haze = current
        // Przezroczyste i wycinane (banery, szyby) zostają przy swoim materiale.
        guard haze.density > 0, pbr.opacityThreshold == nil, case .opaque = pbr.blending,
              var m = SceneShaders.material("hazeSurface")
        else { return nil }
        m.baseColor = .init(tint: pbr.baseColor.tint, texture: pbr.baseColor.texture.map { .init($0.resource) })
        var flags: Float = 0
        if let t = pbr.roughness.texture { m.roughness = .init(scale: pbr.roughness.scale, texture: .init(t.resource)); flags += 1 } else {
            m.roughness = .init(floatLiteral: pbr.roughness.scale)
        }
        if let t = pbr.metallic.texture { m.metallic = .init(scale: pbr.metallic.scale, texture: .init(t.resource)); flags += 2 } else {
            m.metallic = .init(floatLiteral: pbr.metallic.scale)
        }
        if let t = pbr.normal.texture { m.normal = .init(texture: .init(t.resource)); flags += 4 }
        if pbr.baseColor.texture != nil { flags += 8 }
        m.emissiveColor = .init(color: haze.uiColor)
        m.custom.value = [haze.packed, flags, 0, 0]
        return m
    }

    /// Podmienia materiały PBR wszystkich modeli w drzewie na wersje z mgłą; zwraca liczbę podmienionych
    /// (do logu — zero przy włączonej mgle znaczy, że mgły nie ma nigdzie).
    @MainActor @discardableResult static func applyAll(_ root: Entity) -> Int {
        var count = 0
        func visit(_ e: Entity) {
            if let model = e as? ModelEntity, var comp = model.model {
                var changed = false
                comp.materials = comp.materials.map { m in
                    guard let pbr = m as? PhysicallyBasedMaterial, let hazy = apply(pbr) else { return m }
                    changed = true
                    return hazy
                }
                if changed { model.model = comp; count += 1 }
            }
            for c in e.children { visit(c) }
        }
        visit(root)
        return count
    }

    /// Mgła w materiale `CustomMaterial` z własnym shaderem (grunt, jezdnia): kolor w `emissiveColor`.
    @MainActor static func tag(_ m: inout CustomMaterial) {
        m.emissiveColor = .init(color: current.uiColor)
    }

}

/// Materiały z własnymi shaderami otoczenia (Ground.metal). Biblioteka Metal wczytuje się raz, a każdy shader
/// kompiluje się w jednym wzorcu `CustomMaterial` — kolejne materiały są jego kopiami (struktura; kopia
/// dzieli skompilowany shader). Wcześniej każdy materiał wczytywał bibliotekę i budował shader od nowa:
/// budowa trasy z mgłą trwała 1,3 s zamiast 0,7 s (45 materiałów z mgłą + jezdnia i mury).
@MainActor
enum SceneShaders {
    private static let library: (any MTLLibrary)? = MTLCreateSystemDefaultDevice()?.makeDefaultLibrary()
    private static var templates: [String: CustomMaterial] = [:]

    static let names = ["groundSurface", "roadSurface", "wallSurface", "plinthSurface", "hazeSurface"]

    /// Kompiluje wszystkie shadery otoczenia po jednym na turę pętli — wołane na początku ekranu ładowania,
    /// kiedy wątek główny i tak czeka na tekstury wczytywane w tle (bez tego ~0,5 s doliczało się do budowy trasy).
    static func warmUp() async {
        for name in names where templates[name] == nil {
            _ = material(name)
            await Task.yield()
        }
    }

    /// Czysta kopia wzorca dla shadera powierzchni `name` (oświetlany); `nil`, gdy shadera brak.
    static func material(_ name: String) -> CustomMaterial? {
        if let m = templates[name] { return m }
        guard let library, let m = try? CustomMaterial(surfaceShader: .init(named: name, in: library), lightingModel: .lit)
        else { return nil }
        templates[name] = m
        return m
    }
}
