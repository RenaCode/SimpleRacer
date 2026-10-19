import RealityKit
import simd

/// Składa własną siatkę z czworokątów. Wierzchołki czworokąta podaje się przeciwnie do ruchu
/// wskazówek zegara, patrząc od strony, z której ma być widoczny.
struct MeshBuilder {
    private var positions: [SIMD3<Float>] = []
    private var normals: [SIMD3<Float>] = []
    private var indices: [UInt32] = []

    var isEmpty: Bool { indices.isEmpty }

    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                       doubleSided: Bool = false) {
        add(a, b, c, d)
        if doubleSided { add(d, c, b, a) }
    }

    private mutating func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
        let n = simd_normalize(simd_cross(b - a, c - a))
        let base = UInt32(positions.count)
        positions += [a, b, c, d]
        normals += [n, n, n, n]
        indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    }

    func mesh(name: String) throws -> MeshResource {
        var desc = MeshDescriptor(name: name)
        desc.positions = MeshBuffers.Positions(positions)
        desc.normals = MeshBuffers.Normals(normals)
        desc.primitives = .triangles(indices)
        return try MeshResource.generate(from: [desc])
    }
}
