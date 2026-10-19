import RaceCore
import RealityKit
import UIKit

/// Buduje trasę: jezdnia, linie, krawężniki, bandy, trawa, brama startowa i budynki dla poczucia prędkości.
@MainActor
enum TrackBuilder {
    static func build(_ track: Track) throws -> Entity {
        let root = Entity()
        let hw = track.halfWidth

        func p(_ s: Double, _ d: Double, _ y: Float) -> SIMD3<Float> {
            let w = track.toWorld(s: s, d: d)
            return [Float(w.x), y, Float(w.z)]
        }
        /// Pas wzdłuż trasy między przesunięciami dRight < dLeft, od s0 do s1 co ~1 m.
        /// UV w metrach podzielonych przez `tile`, więc tekstura kafelkuje się równo na całej długości.
        func strip(_ b: inout MeshBuilder, _ dRight: Double, _ dLeft: Double, _ s0: Double, _ s1: Double, y: Float, tile: Double = 8) {
            var s = s0
            let u0 = Float(dRight / tile), u1 = Float(dLeft / tile)
            while s < s1 - 1e-6 {
                let e = min(s1, s + track.ds)
                let v0 = Float(s / tile), v1 = Float(e / tile)
                b.quad(p(s, dRight, y), p(e, dRight, y), p(e, dLeft, y), p(s, dLeft, y),
                       uv: [[u0, v0], [u0, v1], [u1, v1], [u1, v0]])
                s = e
            }
        }
        func add(_ b: MeshBuilder, _ name: String, _ material: any Material) throws {
            guard !b.isEmpty else { return }
            root.addChild(ModelEntity(mesh: try b.mesh(name: name), materials: [material]))
        }
        let matte = { (c: UIColor) in Materials.matte(c) }

        var road = MeshBuilder()
        strip(&road, -hw, hw, 0, track.length, y: 0.02)
        try add(road, "road", Materials.roadSurfaceMaterial)

        // Linie: ciągłe przy krawędziach, przerywane między pasami.
        var lines = MeshBuilder()
        for edge in [-hw + 0.3, hw - 0.3] { strip(&lines, edge - 0.12, edge + 0.12, 0, track.length, y: 0.04) }
        for lane in [-hw / 3, hw / 3] {
            var s = 0.0
            while s < track.length { strip(&lines, lane - 0.08, lane + 0.08, s, min(track.length, s + 5), y: 0.04); s += 12 }
        }
        try add(lines, "lines", matte(UIColor(white: 0.93, alpha: 1)))

        // Krawężniki w czerwono-białe pasy po 3 m.
        var red = MeshBuilder(), white = MeshBuilder()
        var s = 0.0, k = 0
        while s < track.length {
            let e = min(track.length, s + 3)
            for (dRight, dLeft) in [(hw, hw + 1.2), (-hw - 1.2, -hw)] {
                if k % 2 == 0 { strip(&red, dRight, dLeft, s, e, y: 0.03) } else { strip(&white, dRight, dLeft, s, e, y: 0.03) }
            }
            s = e; k += 1
        }
        try add(red, "kerb-red", matte(UIColor(red: 0.84, green: 0.16, blue: 0.16, alpha: 1)))
        try add(white, "kerb-white", matte(UIColor(white: 0.96, alpha: 1)))

        var walls = MeshBuilder()
        for side in [1.0, -1.0] {
            let d = side * (hw + 1.4)
            var s = 0.0
            while s < track.length {
                let e = min(track.length, s + track.ds)
                walls.quad(p(s, d, 0), p(e, d, 0), p(e, d, 1.2), p(s, d, 1.2), doubleSided: true)
                s = e
            }
        }
        try add(walls, "walls", matte(UIColor(red: 0.72, green: 0.74, blue: 0.78, alpha: 1)))

        // Trawa: jeden duży czworokąt z kafelkowaną teksturą (co 6 m).
        var grass = MeshBuilder()
        let g: Float = 2000, reps = g / 6
        grass.quad([-g, -0.3, g], [g, -0.3, g], [g, -0.3, -g], [-g, -0.3, -g], uv: [[0, 0], [reps, 0], [reps, reps], [0, reps]])
        try add(grass, "grass", Materials.grassMaterial)

        root.addChild(startGate(track))
        root.addChild(buildings(track))
        root.addChild(roadside(track))
        return root
    }

    private static func startGate(_ track: Track) -> Entity {
        let hw = Float(track.halfWidth)
        let start = track.toWorld(s: 0, d: 0)
        let gate = Entity()
        gate.position = [Float(start.x), 0, Float(start.z)]
        gate.orientation = simd_quatf(angle: Float(start.heading), axis: [0, 1, 0])

        let line = ModelEntity(mesh: .generatePlane(width: hw * 2, depth: 1.5),
                               materials: [SimpleMaterial(color: .white, roughness: 0.8, isMetallic: false)])
        line.position.y = 0.05
        gate.addChild(line)
        let pillar = SimpleMaterial(color: UIColor(white: 0.14, alpha: 1), roughness: 0.5, isMetallic: true)
        for side: Float in [-1, 1] {
            let p = ModelEntity(mesh: .generateBox(width: 0.8, height: 8, depth: 0.8), materials: [pillar])
            p.position = [side * (hw + 2), 4, 0]
            gate.addChild(p)
        }
        let banner = ModelEntity(mesh: .generateBox(width: hw * 2 + 4.8, height: 1.6, depth: 0.5),
                                 materials: [SimpleMaterial(color: UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1), roughness: 0.4, isMetallic: false)])
        banner.position.y = 8
        gate.addChild(banner)
        return gate
    }

    private static func buildings(_ track: Track) -> Entity {
        let root = Entity()
        let rng = SeededRandom(seed: 1234)
        let mesh = MeshResource.generateBox(size: 1)
        let walls: [UIColor] = [
            UIColor(red: 0.78, green: 0.76, blue: 0.72, alpha: 1), UIColor(red: 0.55, green: 0.6, blue: 0.66, alpha: 1),
            UIColor(red: 0.82, green: 0.7, blue: 0.62, alpha: 1), UIColor(red: 0.36, green: 0.39, blue: 0.43, alpha: 1),
        ]
        // Kilka wariantów elewacji; budynek dostaje ten, którego liczba pięter pasuje do wysokości.
        let floorsOptions = [3, 6, 10, 14]
        let facades: [[PhysicallyBasedMaterial]] = floorsOptions.map { floors in
            walls.map { Materials.tiled(Materials.facade(wall: $0, floors: floors, columns: 5), roughness: 0.6, metallic: 0.1) }
        }

        var s = 0.0
        while s < track.length {
            for side in [1.0, -1.0] {
                let off = side * (track.halfWidth + 10 + rng.next() * 25)
                let w = 8 + rng.next() * 10
                let pos = track.toWorld(s: s, d: off)
                let h = 10 + rng.next() * 42
                let depth = 8 + rng.next() * 10
                let floorsIdx = floorsOptions.indices.min { abs(Double(floorsOptions[$0]) * 3.4 - h) < abs(Double(floorsOptions[$1]) * 3.4 - h) }!
                let material = rng.pick(facades[floorsIdx])
                // Nie stawiaj budynku na innym odcinku trasy.
                if track.distanceToAxis(x: pos.x, z: pos.z) < track.halfWidth + 4 + w * 0.75 { continue }
                let b = ModelEntity(mesh: mesh, materials: [material])
                b.scale = [Float(w), Float(h), Float(depth)]
                b.position = [Float(pos.x), Float(h / 2), Float(pos.z)]
                b.orientation = simd_quatf(angle: Float(pos.heading), axis: [0, 1, 0])
                root.addChild(b)
            }
            s += 22
        }
        return root
    }

    /// Drzewa i latarnie między bandą a budynkami.
    private static func roadside(_ track: Track) -> Entity {
        let root = Entity()
        let rng = SeededRandom(seed: 99)
        let hw = track.halfWidth

        let trunk = MeshResource.generateCylinder(height: 2.6, radius: 0.22)
        let crown = MeshResource.generateSphere(radius: 1)
        let bark = Materials.matte(UIColor(red: 0.36, green: 0.25, blue: 0.17, alpha: 1))
        let leaves = [(0.22, 0.42, 0.18), (0.28, 0.5, 0.2), (0.18, 0.36, 0.16)]
            .map { Materials.matte(UIColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1), roughness: 0.95) }
        var s = 6.0
        while s < track.length {
            for side in [1.0, -1.0] where rng.next() < 0.7 {
                let off = side * (hw + 5 + rng.next() * 4)
                let pos = track.toWorld(s: s, d: off)
                guard track.distanceToAxis(x: pos.x, z: pos.z) > hw + 3.5 else { continue }
                let tree = Entity()
                tree.position = [Float(pos.x), 0, Float(pos.z)]
                let t = ModelEntity(mesh: trunk, materials: [bark])
                t.position.y = 1.3
                tree.addChild(t)
                let size = Float(1.6 + rng.next() * 1.0)
                for (k, dy) in [Float(0), 1.1].enumerated() {
                    let c = ModelEntity(mesh: crown, materials: [rng.pick(leaves)])
                    let sc = size * (k == 0 ? 1 : 0.7)
                    c.scale = [sc, sc * 1.1, sc]
                    c.position.y = 2.6 + size * 0.6 + dy * size
                    tree.addChild(c)
                }
                root.addChild(tree)
            }
            s += 16
        }

        let pole = MeshResource.generateCylinder(height: 7, radius: 0.08)
        let arm = MeshResource.generateBox(width: 0.1, height: 0.1, depth: 1.6)
        let head = MeshResource.generateBox(width: 0.3, height: 0.1, depth: 0.6, cornerRadius: 0.04)
        let metal = Materials.matte(UIColor(white: 0.35, alpha: 1), roughness: 0.4, metallic: 0.8)
        let lamp = Materials.glow(UIColor(red: 1, green: 0.95, blue: 0.82, alpha: 1), intensity: 1.5)
        s = 20
        while s < track.length {
            for side in [1.0, -1.0] {
                let pos = track.toWorld(s: s, d: side * (hw + 2.6))
                let e = Entity()
                e.position = [Float(pos.x), 0, Float(pos.z)]
                // Ramię latarni sięga nad jezdnię: obracamy całość tak, by lokalne +Z patrzyło w stronę osi trasy.
                e.orientation = simd_quatf(angle: Float(pos.heading) + (side > 0 ? -.pi / 2 : .pi / 2), axis: [0, 1, 0])
                let p = ModelEntity(mesh: pole, materials: [metal]); p.position.y = 3.5
                let a = ModelEntity(mesh: arm, materials: [metal]); a.position = [0, 6.95, 0.8]
                let h = ModelEntity(mesh: head, materials: [lamp]); h.position = [0, 6.85, 1.45]
                e.addChild(p); e.addChild(a); e.addChild(h)
                root.addChild(e)
            }
            s += 45
        }
        return root
    }
}
