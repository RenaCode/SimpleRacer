import Foundation
import RealityKit

/// Zapieczone ambient occlusion realistycznych aut (`tools/bake-ao.py`): cienie w nadkolach, progach,
/// szczelinach i między szprychami — tego nie da ani panorama, ani mapa cieni słońca.
///
/// Atlas `<model>-ao.png` leży obok USDZ; każda siatka ma w pliku drugi zestaw UV (`primvars:st1`),
/// który RealityKit wczytuje jako bufor „UV1”. Materiał czyta AO z tego zestawu (`uvIndex = 1`) —
/// pierwszy zestaw zostaje dla tekstur modelu, które nakładają się i powtarzają (jedna felga na cztery koła).
@MainActor
enum CarAO {
    /// Bufor drugiego zestawu UV tak, jak nazywa go import USD; ten sam zapisujemy w siatkach scalonych.
    static let uv1 = MeshBuffers.custom("UV1", type: SIMD2<Float>.self)

    /// Część bez UV1 (siatka, której skrypt nie przeniósł) czyta biały pas na brzegu atlasu — bez cienia.
    static let unlitUV1 = SIMD2<Float>(0.995, 0.995)

    /// Atlas AO modelu albo nil, gdy go nie ma (model bez zapiekania albo `-noAO`).
    static func atlas(for file: String, in folder: URL) async -> TextureResource? {
        #if DEBUG || FAMILY
        // Porównanie przed/po w tym samym kadrze: `-noAO`.
        if ProcessInfo.processInfo.arguments.contains("-noAO") { return nil }
        #endif
        let name = ((file as NSString).deletingPathExtension) + "-ao.png"
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Dane, nie kolor: wartości z atlasu idą wprost do materiału, bez krzywej sRGB.
        return try? await TextureResource(contentsOf: url, options: .init(semantic: .raw, mipmapsMode: .allocateAndGenerateAll))
    }

    /// Podpina atlas w materiałach nieprzezroczystych siatek, które mają UV1 (szyby zostają bez AO —
    /// przyciemniałyby się od wnętrza auta). Przed scaleniem siatek, żeby części z tym samym materiałem
    /// dalej się łączyły.
    /// Kawałkami (`MainThreadSlices`): odczyt zawartości siatek kosztował w jednym ciągu do 250 ms na auto.
    static func apply(_ atlas: TextureResource, to root: Entity, file: String) async {
        var texture = MaterialParameters.Texture(atlas)
        texture.uvIndex = 1
        var count = 0, skipped = 0
        var models: [ModelEntity] = []
        func walk(_ e: Entity) {
            if let m = e as? ModelEntity, m.model != nil { models.append(m) }
            for c in e.children { walk(c) }
        }
        walk(root)
        let slices = MainThreadSlices()
        for m in models {
            guard var model = m.model else { continue }
            let parts = model.mesh.contents.models.flatMap { Array($0.parts) }
            if !parts.isEmpty, parts.allSatisfy({ $0[uv1] != nil }) {
                model.materials = model.materials.map { material in
                    guard var p = material as? PhysicallyBasedMaterial, case .opaque = p.blending else { return material }
                    p.ambientOcclusion = .init(texture: texture)
                    return p
                }
                m.model = model
                count += 1
            } else {
                skipped += 1
            }
            await slices.pause()
        }
        debugLog("model: \(file) — AO: \(count) części" + (skipped > 0 ? ", bez UV1: \(skipped)" : ""))
    }
}
