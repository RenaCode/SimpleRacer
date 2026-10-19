import Foundation
import RaceCore
import RealityKit
import simd

/// Scala wiele ustawień tych samych modeli OBJ (drzewa, latarnie, budynki) w kilka dużych siatek —
/// po jednej na materiał. Setki osobnych obiektów to setki poleceń rysowania na klatkę; po scaleniu
/// karta graficzna dostaje ich kilkanaście. Działa dla scenerii, która się nie rusza.
@MainActor
final class PropBatcher {
    private struct Key: Hashable {
        let folder: URL
        let material: String
    }

    private struct Buffers {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        var material = ObjMaterial()
        var hasUV = true
    }

    private var buffers: [Key: Buffers] = [:]
    private(set) var placed = 0

    /// Dodaje model `path` (np. "Track/treeLarge") wyśrodkowany w X/Z i postawiony na y = 0,
    /// przeskalowany o `scale`, obrócony o `yaw` i przesunięty do `position`. Zwraca false, gdy modelu brak.
    @discardableResult
    func add(_ path: String, scale: Float, yaw: Float, position: SIMD3<Float>) -> Bool {
        guard let l = ModelLibrary.shared.load(path) else { return false }
        let b = l.model.bounds
        let center = SIMD3<Float>((b.min.x + b.max.x) / 2, b.min.y, (b.min.z + b.max.z) / 2)
        let rot = simd_quatf(angle: yaw, axis: [0, 1, 0])
        for g in l.model.groups {
            for p in g.parts {
                let key = Key(folder: l.folder, material: p.material)
                var buf = buffers[key] ?? Buffers(material: l.materials[p.material] ?? ObjMaterial())
                let base = UInt32(buf.positions.count)
                buf.positions += p.positions.map { position + rot.act(($0 - center) * scale) }
                buf.normals += p.normals.isEmpty
                    ? Array(repeating: [0, 1, 0], count: p.positions.count)
                    : p.normals.map { rot.act($0) }
                if p.uvs.count == p.positions.count {
                    buf.uvs += p.uvs
                } else {
                    buf.hasUV = false
                }
                buf.indices += p.indices.map { $0 + base }
                buffers[key] = buf
            }
        }
        placed += 1
        return true
    }

    /// Jedna encja ze scalonymi siatkami.
    func build() -> Entity {
        let root = Entity()
        let lib = ModelLibrary.shared
        for (key, buf) in buffers where !buf.indices.isEmpty {
            var desc = MeshDescriptor(name: key.material)
            desc.positions = MeshBuffers.Positions(buf.positions)
            desc.normals = MeshBuffers.Normals(buf.normals)
            if buf.hasUV { desc.textureCoordinates = MeshBuffers.TextureCoordinates(buf.uvs) }
            desc.primitives = .triangles(buf.indices)
            guard let mesh = try? MeshResource.generate(from: [desc]) else { continue }
            root.addChild(ModelEntity(mesh: mesh, materials: [lib.material(buf.material, folder: key.folder)]))
        }
        return root
    }
}
