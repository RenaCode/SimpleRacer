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
        func strip(_ b: inout MeshBuilder, _ dRight: Double, _ dLeft: Double, _ s0: Double, _ s1: Double, y: Float) {
            var s = s0
            while s < s1 - 1e-6 {
                let e = min(s1, s + track.ds)
                b.quad(p(s, dRight, y), p(e, dRight, y), p(e, dLeft, y), p(s, dLeft, y))
                s = e
            }
        }
        func add(_ b: MeshBuilder, _ name: String, _ material: any Material) throws {
            guard !b.isEmpty else { return }
            root.addChild(ModelEntity(mesh: try b.mesh(name: name), materials: [material]))
        }
        let matte = { (c: UIColor) in SimpleMaterial(color: c, roughness: 0.9, isMetallic: false) }

        var road = MeshBuilder()
        strip(&road, -hw, hw, 0, track.length, y: 0.02)
        try add(road, "road", matte(UIColor(red: 0.23, green: 0.24, blue: 0.27, alpha: 1)))

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

        let ground = ModelEntity(mesh: .generatePlane(width: 4000, depth: 4000),
                                 materials: [matte(UIColor(red: 0.36, green: 0.46, blue: 0.33, alpha: 1))])
        ground.position.y = -0.3
        root.addChild(ground)

        root.addChild(startGate(track))
        root.addChild(buildings(track))
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
        let palette: [SimpleMaterial] = [
            (0.55, 0.60, 0.68), (0.42, 0.46, 0.49), (0.68, 0.71, 0.74),
            (0.29, 0.31, 0.34), (0.79, 0.68, 0.65), (0.60, 0.55, 0.60),
        ].map { SimpleMaterial(color: UIColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1), roughness: 0.9, isMetallic: false) }

        var s = 0.0
        while s < track.length {
            for side in [1.0, -1.0] {
                let off = side * (track.halfWidth + 10 + rng.next() * 25)
                let w = 8 + rng.next() * 10
                let pos = track.toWorld(s: s, d: off)
                let h = 8 + rng.next() * 45
                let depth = 8 + rng.next() * 10
                let material = rng.pick(palette)
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
}
