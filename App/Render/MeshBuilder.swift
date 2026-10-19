import RealityKit
import simd

/// Składa własną siatkę z czworokątów. Wierzchołki czworokąta podaje się przeciwnie do ruchu
/// wskazówek zegara, patrząc od strony, z której ma być widoczny.
struct MeshBuilder {
    private var positions: [SIMD3<Float>] = []
    private var normals: [SIMD3<Float>] = []
    private var uvs: [SIMD2<Float>] = []
    private var indices: [UInt32] = []

    var isEmpty: Bool { indices.isEmpty }

    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                       uv: [SIMD2<Float>] = [[0, 0], [1, 0], [1, 1], [0, 1]], doubleSided: Bool = false) {
        add(a, b, c, d, uv)
        if doubleSided { add(d, c, b, a, uv.reversed()) }
    }

    private mutating func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ uv: [SIMD2<Float>]) {
        let n = simd_normalize(simd_cross(b - a, c - a))
        let base = UInt32(positions.count)
        positions += [a, b, c, d]
        normals += [n, n, n, n]
        uvs += uv
        indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    }

    func mesh(name: String) throws -> MeshResource {
        var desc = MeshDescriptor(name: name)
        desc.positions = MeshBuffers.Positions(positions)
        desc.normals = MeshBuffers.Normals(normals)
        desc.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        desc.primitives = .triangles(indices)
        return try MeshResource.generate(from: [desc])
    }
}

/// Gładka bryła „wyciągnięta” przez kolejne przekroje (pierścienie), z uśrednionymi normalnymi —
/// z tego powstają opływowe nadwozia aut.
struct LoftBuilder {
    private var positions: [SIMD3<Float>] = []
    private var indices: [UInt32] = []

    /// `rings` — przekroje ułożone wzdłuż bryły; każdy ma tyle samo punktów.
    /// `closed` — czy przekrój jest zamknięty (pełny obwód), `capEnds` — czy zamknąć oba końce.
    mutating func loft(_ rings: [[SIMD3<Float>]], closed: Bool, capEnds: Bool) {
        guard let n = rings.first?.count, rings.count > 1 else { return }
        let base = UInt32(positions.count)
        for r in rings { positions += r }
        let segs = closed ? n : n - 1
        for i in 0..<(rings.count - 1) {
            let c0 = centroid(rings[i]), c1 = centroid(rings[i + 1])
            for j in 0..<segs {
                let j1 = (j + 1) % n
                let a = base + UInt32(i * n + j), b = base + UInt32((i + 1) * n + j)
                let c = base + UInt32((i + 1) * n + j1), d = base + UInt32(i * n + j1)
                let pa = positions[Int(a)], pb = positions[Int(b)], pc = positions[Int(c)]
                // Ściany mają patrzeć na zewnątrz — orientację sprawdzamy względem osi bryły.
                let nrm = simd_cross(pb - pa, pc - pa)
                let outward = (pa + pc) / 2 - (c0 + c1) / 2
                if simd_dot(nrm, outward) >= 0 { indices += [a, b, c, a, c, d] } else { indices += [a, c, b, a, d, c] }
            }
        }
        if capEnds {
            cap(ringStart: base, count: n, outward: centroid(rings[0]) - centroid(rings[1]))
            cap(ringStart: base + UInt32((rings.count - 1) * n), count: n,
                outward: centroid(rings[rings.count - 1]) - centroid(rings[rings.count - 2]))
        }
    }

    private mutating func cap(ringStart: UInt32, count n: Int, outward: SIMD3<Float>) {
        let ring = (0..<n).map { positions[Int(ringStart) + $0] }
        let center = UInt32(positions.count)
        positions.append(centroid(ring))
        for j in 0..<n {
            let a = ringStart + UInt32(j), b = ringStart + UInt32((j + 1) % n)
            let nrm = simd_cross(positions[Int(a)] - positions[Int(center)], positions[Int(b)] - positions[Int(center)])
            if simd_dot(nrm, outward) >= 0 { indices += [center, a, b] } else { indices += [center, b, a] }
        }
    }

    private func centroid(_ r: [SIMD3<Float>]) -> SIMD3<Float> {
        r.reduce(SIMD3<Float>(repeating: 0), +) / Float(r.count)
    }

    func mesh(name: String) throws -> MeshResource {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += n; normals[b] += n; normals[c] += n
        }
        normals = normals.map { simd_length($0) > 1e-9 ? simd_normalize($0) : [0, 1, 0] }
        var desc = MeshDescriptor(name: name)
        desc.positions = MeshBuffers.Positions(positions)
        desc.normals = MeshBuffers.Normals(normals)
        desc.primitives = .triangles(indices)
        return try MeshResource.generate(from: [desc])
    }
}
