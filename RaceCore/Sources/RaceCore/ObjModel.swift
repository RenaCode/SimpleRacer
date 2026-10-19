/// Materiał z pliku .mtl: kolor rozproszony i opcjonalna tekstura (ścieżka względna do pliku .mtl).
public struct ObjMaterial: Equatable {
    public var diffuse: SIMD3<Float> = [1, 1, 1]
    public var texture: String?

    public init(diffuse: SIMD3<Float> = [1, 1, 1], texture: String? = nil) {
        self.diffuse = diffuse
        self.texture = texture
    }
}

/// Fragment grupy z jednym materiałem, gotowy do zbudowania siatki (wierzchołki już rozwinięte z indeksów OBJ).
public struct ObjPart {
    public var material: String
    public var positions: [SIMD3<Float>] = []
    public var normals: [SIMD3<Float>] = []
    public var uvs: [SIMD2<Float>] = []
    public var indices: [UInt32] = []
}

public struct ObjGroup {
    public var name: String
    public var parts: [ObjPart]
}

/// Minimalny czytnik Wavefront OBJ: grupy (`g`/`o`), materiały (`usemtl`), wielokąty dzielone na trójkąty.
/// Wystarcza dla modeli z paczek CC0 (Kenney) i pozwala podmienić model, wrzucając inny plik OBJ.
public struct ObjModel {
    public var groups: [ObjGroup]
    /// Nazwa pliku .mtl z linii `mtllib`, jeśli była.
    public var materialLibrary: String?

    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for g in groups { for p in g.parts { for v in p.positions { lo = pointwiseMin(lo, v); hi = pointwiseMax(hi, v) } } }
        return (lo, hi)
    }

    public func group(named name: String) -> ObjGroup? { groups.first { $0.name == name } }

    public static func parse(_ text: String) -> ObjModel {
        var v: [SIMD3<Float>] = [], vt: [SIMD2<Float>] = [], vn: [SIMD3<Float>] = []
        var groups: [ObjGroup] = []
        var library: String?
        var groupName = "default"
        var material = "default"
        // Rozwinięte wierzchołki są wspólne w obrębie części: klucz (v, vt, vn) → indeks.
        var cache: [String: [Int: UInt32]] = [:]
        var current: (g: Int, p: Int)?

        func part() -> (Int, Int) {
            if let c = current { return c }
            if groups.last?.name != groupName { groups.append(ObjGroup(name: groupName, parts: [])) }
            let gi = groups.count - 1
            if let pi = groups[gi].parts.firstIndex(where: { $0.material == material }) {
                current = (gi, pi)
            } else {
                groups[gi].parts.append(ObjPart(material: material))
                current = (gi, groups[gi].parts.count - 1)
            }
            return current!
        }
        func resolve(_ i: Int, _ count: Int) -> Int { i < 0 ? count + i : i - 1 }

        for raw in text.split(whereSeparator: \.isNewline) {
            let f = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard let head = f.first else { continue }
            switch head {
            case "v" where f.count >= 4:
                v.append([Float(f[1]) ?? 0, Float(f[2]) ?? 0, Float(f[3]) ?? 0])
            case "vt" where f.count >= 3:
                vt.append([Float(f[1]) ?? 0, Float(f[2]) ?? 0])
            case "vn" where f.count >= 4:
                vn.append([Float(f[1]) ?? 0, Float(f[2]) ?? 0, Float(f[3]) ?? 0])
            case "g", "o":
                groupName = f.count > 1 ? f[1...].joined(separator: " ") : "default"
                current = nil
            case "usemtl":
                material = f.count > 1 ? String(f[1]) : "default"
                current = nil
            case "mtllib" where f.count > 1:
                library = f[1...].joined(separator: " ")
            case "f" where f.count >= 4:
                let (gi, pi) = part()
                let key = "\(gi)/\(pi)"
                var corners: [UInt32] = []
                for c in f[1...] {
                    let idx = c.split(separator: "/", omittingEmptySubsequences: false).map { Int($0) }
                    guard let vi = idx.first ?? nil else { continue }
                    let pv = resolve(vi, v.count)
                    let pt = idx.count > 1 ? idx[1].map { resolve($0, vt.count) } : nil
                    let pn = idx.count > 2 ? idx[2].map { resolve($0, vn.count) } : nil
                    let hash = (pv &* 73_856_093) ^ ((pt ?? -1) &* 19_349_663) ^ ((pn ?? -1) &* 83_492_791)
                    if let existing = cache[key]?[hash] {
                        corners.append(existing)
                        continue
                    }
                    var p = groups[gi].parts[pi]
                    let index = UInt32(p.positions.count)
                    p.positions.append(v[pv])
                    if let pt, pt < vt.count { p.uvs.append(vt[pt]) }
                    if let pn, pn < vn.count { p.normals.append(vn[pn]) }
                    groups[gi].parts[pi] = p
                    cache[key, default: [:]][hash] = index
                    corners.append(index)
                }
                // Wielokąt → wachlarz trójkątów.
                for k in 1..<max(1, corners.count - 1) {
                    groups[gi].parts[pi].indices += [corners[0], corners[k], corners[k + 1]]
                }
            default:
                break
            }
        }
        // Niespójne dane (część wierzchołków bez UV/normalnych) — odrzucamy cały kanał.
        for gi in groups.indices {
            for pi in groups[gi].parts.indices {
                let n = groups[gi].parts[pi].positions.count
                if groups[gi].parts[pi].uvs.count != n { groups[gi].parts[pi].uvs = [] }
                if groups[gi].parts[pi].normals.count != n { groups[gi].parts[pi].normals = [] }
            }
        }
        return ObjModel(groups: groups.filter { $0.parts.contains { !$0.indices.isEmpty } }, materialLibrary: library)
    }

    public static func parseMaterials(_ text: String) -> [String: ObjMaterial] {
        var out: [String: ObjMaterial] = [:]
        var name: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let f = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard let head = f.first else { continue }
            switch head {
            case "newmtl" where f.count > 1:
                name = String(f[1])
                out[name!] = ObjMaterial()
            case "Kd" where f.count >= 4:
                if let n = name { out[n]?.diffuse = [Float(f[1]) ?? 1, Float(f[2]) ?? 1, Float(f[3]) ?? 1] }
            case "map_Kd" where f.count > 1:
                if let n = name { out[n]?.texture = f[1...].joined(separator: " ") }
            default:
                break
            }
        }
        return out
    }
}
