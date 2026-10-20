import Foundation
import RealityKit
import UIKit

/// Scalanie siatek realistycznego modelu auta (raz na model, przy normalizacji wzorca w `LocalAssets`).
///
/// Model z USDZ to setki osobnych prim — po klonowaniu każdy jest osobnym `ModelEntity` (osobna encja,
/// osobne polecenie rysowania), a w wyścigu jest sześć aut. Tu sklejamy części w kilka siatek:
/// - nadwozie bez lakieru (`merged_body`),
/// - lakier (`merged_paint_body`) — przemalowywany per auto,
/// - każde z czterech kół osobno (`merged_wheel_N`, a jego lakierowane części `merged_paint_wheel_N`) —
///   koła rozpoznajemy tą samą regułą co `CarEntity.rigRealisticWheels` (nazwy i ćwiartka auta),
///   więc po scaleniu dalej obracają się wokół własnych osi.
/// W każdej siatce części o tym samym materiale łączymy w jedną część (jedno rysowanie na materiał).
/// Wierzchołki przenosimy do układu wzorca: pozycje macierzą, normalne macierzą odwrotną transponowaną,
/// styczne i binormalne macierzą 3×3; UV kopiujemy bez zmian. Kolejność wierzchołków w trójkątach zostaje
/// taka jak w pliku także dla części odbitych lustrzanie (ujemny wyznacznik): RealityKit rysuje je bez
/// odwracania, więc odwrócenie przy scalaniu chowało felgi i opony lewych kół (zostawała sama tarcza hamulca).
@MainActor
enum CarMeshMerge {
    static let paintPrefix = "merged_paint"

    /// Zwraca nowy wzorzec (te same współrzędne co `template`) albo nil, gdy scalanie się nie udało.
    static func merge(_ template: Entity, paintNames: Set<String>, file: String) -> Entity? {
        let wheelGroups = CarEntity.realisticWheelGroups(template, space: template)
        var wheelOf: [ObjectIdentifier: Int] = [:]
        for (i, g) in (wheelGroups ?? []).enumerated() {
            for e in g { wheelOf[ObjectIdentifier(e)] = i }
        }
        // Grupy wyjściowe: -1 = nadwozie, 0…3 = koła; osobno lakier.
        struct Key: Hashable { var wheel: Int; var paint: Bool }
        var buckets: [Key: Bucket] = [:]
        var sourceCount = 0
        func walk(_ e: Entity, inPaint: Bool) {
            let paint = inPaint || paintNames.contains(e.name)
            if let m = e as? ModelEntity, m.isEnabled, let model = m.model {
                sourceCount += 1
                let wheel = wheelOf[ObjectIdentifier(m)] ?? -1
                // Część koła lakierujemy tylko wymienioną z nazwy — opona podpięta w pliku pod lakierowaną
                // karoserię dziedziczyła lakier (czerwona opona SLS).
                let key = Key(wheel: wheel, paint: wheel >= 0 ? paintNames.contains(e.name) : paint)
                buckets[key, default: Bucket()].add(model, transform: m.transformMatrix(relativeTo: template))
            }
            for c in e.children { walk(c, inPaint: paint) }
        }
        walk(template, inPaint: false)

        let root = Entity()
        root.name = template.name
        var parts = 0, draws = 0
        for (key, bucket) in buckets.sorted(by: { ($0.key.wheel, $0.key.paint ? 1 : 0) < ($1.key.wheel, $1.key.paint ? 1 : 0) }) {
            let name = (key.paint ? paintPrefix + "_" : "merged_") + (key.wheel < 0 ? "body" : "wheel_\(key.wheel)")
            guard let entity = bucket.build(name: name) else {
                debugLog("model: \(file) — scalanie \(name) nie powiodło się")
                return nil
            }
            parts += bucket.sourceParts
            draws += bucket.groups.count
            root.addChild(entity)
        }
        debugLog("model: \(file) scalony — \(sourceCount) encji (\(parts) części) → \(root.children.count) encji, \(draws) materiałów"
                 + (wheelGroups == nil ? ", koła nierozpoznane" : ""))
        return root
    }

    /// Części jednej siatki wyjściowej, pogrupowane wg materiału.
    @MainActor private struct Bucket {
        struct Group {
            var material: any Material
            var positions: [SIMD3<Float>] = []
            var normals: [SIMD3<Float>] = []
            var tangents: [SIMD3<Float>] = []
            var bitangents: [SIMD3<Float>] = []
            var uvs: [SIMD2<Float>] = []
            var indices: [UInt32] = []
            var hasUV = true
        }
        var groups: [Group] = []
        var index: [String: Int] = [:]
        var sourceParts = 0

        mutating func add(_ model: ModelComponent, transform entityM: simd_float4x4) {
            let contents = model.mesh.contents
            for inst in contents.instances {
                guard let m = contents.models[inst.model] else { continue }
                let M = entityM * inst.transform
                let M3 = simd_float3x3(SIMD3(M.columns.0.x, M.columns.0.y, M.columns.0.z),
                                       SIMD3(M.columns.1.x, M.columns.1.y, M.columns.1.z),
                                       SIMD3(M.columns.2.x, M.columns.2.y, M.columns.2.z))
                let N3 = M3.inverse.transpose
                for part in m.parts {
                    guard let pos = part[MeshBuffers.positions]?.elements, let tri = part.triangleIndices?.elements,
                          !pos.isEmpty, !tri.isEmpty else { continue }
                    sourceParts += 1
                    let mi = min(max(0, part.materialIndex), max(0, model.materials.count - 1))
                    let material: any Material = model.materials.isEmpty ? SimpleMaterial() : model.materials[mi]
                    let key = CarMeshMerge.materialKey(material) ?? "unique-\(groups.count)"
                    let gi: Int
                    if let i = index[key] {
                        gi = i
                    } else {
                        gi = groups.count
                        index[key] = gi
                        groups.append(Group(material: material))
                    }
                    let n = part[MeshBuffers.normals]?.elements
                    let uv = part[MeshBuffers.textureCoordinates]?.elements
                    var t = part[MeshBuffers.tangents]?.elements
                    var b = part[MeshBuffers.bitangents]?.elements
                    let normals = n?.count == pos.count ? n! : CarMeshMerge.faceNormals(pos, tri)
                    if t?.count != pos.count || b?.count != pos.count {
                        let tb = CarMeshMerge.tangents(pos, normals, uv?.count == pos.count ? uv : nil, tri)
                        t = tb.t; b = tb.b
                    }
                    let base = UInt32(groups[gi].positions.count)
                    groups[gi].positions += pos.map { p in let v = M * SIMD4(p, 1); return SIMD3(v.x, v.y, v.z) }
                    groups[gi].normals += normals.map { safeNormalize(N3 * $0) }
                    groups[gi].tangents += t!.map { safeNormalize(M3 * $0) }
                    groups[gi].bitangents += b!.map { safeNormalize(M3 * $0) }
                    if let uv, uv.count == pos.count {
                        groups[gi].uvs += uv
                    } else {
                        groups[gi].uvs += [SIMD2<Float>](repeating: .zero, count: pos.count)
                        groups[gi].hasUV = false
                    }
                    groups[gi].indices += tri.map { base + $0 }
                }
            }
        }

        func build(name: String) -> ModelEntity? {
            var parts: [MeshResource.Part] = []
            for (i, g) in groups.enumerated() {
                var p = MeshResource.Part(id: "\(name)-\(i)", materialIndex: i)
                p[MeshBuffers.positions] = MeshBuffer(g.positions)
                p[MeshBuffers.normals] = MeshBuffer(g.normals)
                p[MeshBuffers.tangents] = MeshBuffer(g.tangents)
                p[MeshBuffers.bitangents] = MeshBuffer(g.bitangents)
                p[MeshBuffers.textureCoordinates] = MeshBuffer(g.uvs)
                p.triangleIndices = MeshBuffer(g.indices)
                parts.append(p)
            }
            var contents = MeshResource.Contents()
            contents.models = MeshModelCollection([MeshResource.Model(id: name, parts: parts)])
            contents.instances = MeshInstanceCollection([MeshResource.Instance(id: name, model: name)])
            guard let mesh = try? MeshResource.generate(from: contents) else { return nil }
            let e = ModelEntity(mesh: mesh, materials: groups.map(\.material))
            e.name = name
            return e
        }
    }

    /// Klucz materiału: te same parametry i te same tekstury = ten sam materiał (części łączymy).
    /// Materiały inne niż PBR nie są łączone (nil).
    static func materialKey(_ m: any Material) -> String? {
        guard let p = m as? PhysicallyBasedMaterial else { return nil }
        // Tożsamość tekstury: wskaźnik zasobu silnika (`__coreAsset`). Obiekt `TextureResource` z materiału
        // jest tworzony przy każdym odczycie i zaraz zwalniany — jego adres (ObjectIdentifier) bywa ponownie
        // użyty przez inną teksturę, więc dawał zarówno fałszywe rozdzielenia, jak i fałszywe złączenia.
        func t(_ x: MaterialParameters.Texture?) -> String {
            guard let x else { return "-" }
            return "\(x.resource.__coreAsset)"
        }
        func c(_ u: UIColor) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            u.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "%.4f,%.4f,%.4f,%.4f", r, g, b, a)
        }
        func blending(_ b: PhysicallyBasedMaterial.Blending) -> String {
            switch b {
            case .opaque: return "opaque"
            case let .transparent(opacity): return "transparent \(opacity.scale) \(t(opacity.texture))"
            @unknown default: return "\(b)"
            }
        }
        return [
            c(p.baseColor.tint), t(p.baseColor.texture),
            "\(p.metallic.scale)", t(p.metallic.texture),
            "\(p.roughness.scale)", t(p.roughness.texture),
            t(p.normal.texture),
            c(p.emissiveColor.color), t(p.emissiveColor.texture), "\(p.emissiveIntensity)",
            t(p.ambientOcclusion.texture),
            "\(p.specular.scale)", t(p.specular.texture),
            "\(p.clearcoat.scale)", t(p.clearcoat.texture),
            "\(p.clearcoatRoughness.scale)", t(p.clearcoatRoughness.texture),
            blending(p.blending), "\(String(describing: p.opacityThreshold))", "\(p.faceCulling)",
            "\(p.textureCoordinateTransform)", "\(p.triangleFillMode)",
        ].joined(separator: "|")
    }

    private static func faceNormals(_ pos: [SIMD3<Float>], _ tri: [UInt32]) -> [SIMD3<Float>] {
        var n = [SIMD3<Float>](repeating: .zero, count: pos.count)
        var k = 0
        while k + 2 < tri.count {
            let a = Int(tri[k]), b = Int(tri[k + 1]), c = Int(tri[k + 2])
            let f = simd_cross(pos[b] - pos[a], pos[c] - pos[a])
            n[a] += f; n[b] += f; n[c] += f
            k += 3
        }
        return n.map { safeNormalize($0) }
    }

    /// Styczne z UV (suma po trójkątach, ortogonalizacja Grama–Schmidta) — gdy plik ich nie miał.
    private static func tangents(_ pos: [SIMD3<Float>], _ nrm: [SIMD3<Float>], _ uv: [SIMD2<Float>]?,
                                 _ tri: [UInt32]) -> (t: [SIMD3<Float>], b: [SIMD3<Float>]) {
        var ts = [SIMD3<Float>](repeating: .zero, count: pos.count)
        var bs = ts
        if let uv {
            var k = 0
            while k + 2 < tri.count {
                let a = Int(tri[k]), b = Int(tri[k + 1]), c = Int(tri[k + 2])
                let e1 = pos[b] - pos[a], e2 = pos[c] - pos[a]
                let d1 = uv[b] - uv[a], d2 = uv[c] - uv[a]
                let det = d1.x * d2.y - d2.x * d1.y
                if abs(det) > 1e-12 {
                    let r = 1 / det
                    let t = (e1 * d2.y - e2 * d1.y) * r
                    let bt = (e2 * d1.x - e1 * d2.x) * r
                    for i in [a, b, c] { ts[i] += t; bs[i] += bt }
                }
                k += 3
            }
        }
        for i in 0..<pos.count {
            let n = nrm[i]
            var t = ts[i] - n * simd_dot(n, ts[i])
            if simd_length_squared(t) < 1e-12 {
                // Bez UV: dowolny kierunek prostopadły do normalnej.
                t = abs(n.x) < 0.9 ? simd_cross(n, [1, 0, 0]) : simd_cross(n, [0, 1, 0])
            }
            t = safeNormalize(t)
            let sign: Float = simd_dot(simd_cross(n, t), bs[i]) < 0 ? -1 : 1
            ts[i] = t
            bs[i] = simd_cross(n, t) * sign
        }
        return (ts, bs)
    }
}

private func safeNormalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let l = simd_length(v)
    return l > 1e-12 ? v / l : [0, 1, 0]
}
