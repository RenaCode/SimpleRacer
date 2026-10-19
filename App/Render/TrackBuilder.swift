import RaceCore
import RealityKit
import UIKit

/// Buduje trasę: jezdnia, linie, krawężniki, bandy, trawa, brama startowa i budynki dla poczucia prędkości.
@MainActor
enum TrackBuilder {
    /// Obiekty otoczenia rozstawione wzdłuż trasy (do ukrywania tych daleko od gracza) — `s` to ich miejsce na trasie.
    static var cullables: [(entity: Entity, s: Double)] = []

    static func build(_ track: Track, theme: TrackTheme = .of(.city), region: Region = .city) throws -> Entity {
        cullables = []
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
        try add(grass, "grass", Materials.ground(theme.ground))

        root.addChild(startGate(track))
        root.addChild(startArea(track))
        let realBuildings = LocalAssets.shared.scenery("building", region: region)
        root.addChild(realBuildings.isEmpty ? buildings(track, theme: theme)
                      : realisticBuildings(track, theme: theme, pieces: realBuildings))
        root.addChild(roadside(track, theme: theme, region: region))
        root.addChild(backdrop(track, region: region))
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

        let lib = ModelLibrary.shared
        if let size = lib.size("Track/overhead"),
           let overhead = lib.prop("Track/overhead", scale: (2 * hw + 4) / size.x) {
            gate.addChild(overhead)
            return gate
        }
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

    /// Kąt obrotu wokół Y, przy którym lokalne +Z modelu patrzy z boku trasy na jej oś.
    static func facingAxis(heading: Double, side: Double) -> Float {
        Float(heading) + (side > 0 ? -.pi / 2 : .pi / 2)
    }

    private static let cityModels = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n"]
        .map { "City/building-\($0)" }
    private static let skyscrapers = ["a", "b", "c", "d", "e"].map { "City/building-skyscraper-\($0)" }

    /// Strefa przy linii startu zarezerwowana na trybuny i namioty (bez budynków).
    private static func isStartArea(_ s: Double, _ track: Track) -> Bool {
        s > track.length - 110 || s < 15
    }

    private static func buildings(_ track: Track, theme: TrackTheme) -> Entity {
        guard theme.buildings > 0 else { return Entity() }
        let lib = ModelLibrary.shared
        let regular = cityModels.filter { lib.size($0) != nil }
        let tall = skyscrapers.filter { lib.size($0) != nil }
        guard !regular.isEmpty else { return boxBuildings(track) }

        let batch = PropBatcher()
        let rng = SeededRandom(seed: 1234)
        let hw = track.halfWidth
        for side in [1.0, -1.0] {
            var s = 0.0
            while s < track.length {
                let path = (!tall.isEmpty && rng.next() < 0.25 * theme.buildings) ? rng.pick(tall) : rng.pick(regular)
                let size = lib.size(path)!
                let scale = Float(12 + rng.next() * 6)
                let footprint = Double(max(size.x, size.z) * scale)
                let offset = side * (hw + 9 + footprint / 2 + rng.next() * 12)
                let pos = track.toWorld(s: s + footprint / 2, d: offset)
                let skip = isStartArea(s, track) || rng.next() > theme.buildings
                    || track.distanceToAxis(x: pos.x, z: pos.z) < hw + 6 + footprint * 0.6
                if !skip {
                    batch.add(path, scale: scale, yaw: facingAxis(heading: pos.heading, side: side),
                              position: [Float(pos.x), 0, Float(pos.z)])
                }
                s += footprint + 3 + rng.next() * 6
            }
        }
        return batch.build()
    }

    /// Zapas, gdy modeli budynków nie ma w paczce: bryły z elewacją z oknami.
    private static func boxBuildings(_ track: Track) -> Entity {
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

    /// Trybuny, namioty i flagi w szachownicę wokół linii startu.
    private static func startArea(_ track: Track) -> Entity {
        let root = Entity()
        let lib = ModelLibrary.shared
        let hw = track.halfWidth
        func place(_ path: String, scale: Float, s: Double, d: Double, side: Double) {
            guard let e = lib.prop(path, scale: scale) else { return }
            let p = track.toWorld(s: s, d: d)
            e.position = [Float(p.x), 0, Float(p.z)]
            e.orientation = simd_quatf(angle: facingAxis(heading: p.heading, side: side), axis: [0, 1, 0])
            root.addChild(e)
        }
        // Trybuny po obu stronach tuż przed metą, namioty dalej.
        for (k, s) in [-28.0, -52.0, -76.0].enumerated() {
            place("Track/grandStandCovered", scale: 13, s: s, d: hw + 10, side: 1)
            if k < 2 { place("Track/grandStandCovered", scale: 13, s: s - 10, d: -(hw + 10), side: -1) }
        }
        for s in [-96.0, -104.0] { place("Track/tent", scale: 7, s: s, d: -(hw + 7), side: -1) }
        for side in [1.0, -1.0] { place("Track/flagCheckers", scale: 3.2, s: 3, d: side * (hw + 2.2), side: side) }
        return root
    }

    /// Drzewa i latarnie między bandą a budynkami.
    /// Klon obiektu otoczenia przeskalowany do wysokości `height` m, obrócony i postawiony w `position`.
    private static func place(_ piece: SceneryPiece, height: Float, yaw: Float, position: SIMD3<Float>) -> Entity {
        let e = piece.template.clone(recursive: true)
        let k = height / piece.height
        e.scale = [k, k, k]
        e.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        e.position = position
        return e
    }

    private static func randomHeight(_ piece: SceneryPiece, _ rng: SeededRandom) -> Float {
        let lo = piece.entry.height.first ?? 10, hi = piece.entry.height.last ?? lo
        return Float(lo + (hi - lo) * rng.next())
    }

    /// Realistyczne budynki (modele lokalne) wzdłuż trasy, frontem do niej; limit sztuk dla ciężkich modeli.
    private static func realisticBuildings(_ track: Track, theme: TrackTheme, pieces: [SceneryPiece]) -> Entity {
        let root = Entity()
        let rng = SeededRandom(seed: 4321)
        let hw = track.halfWidth
        var used: [String: Int] = [:]
        for side in [1.0, -1.0] {
            var s = 0.0
            while s < track.length {
                let available = pieces.filter { ($0.entry.max ?? .max) > (used[$0.entry.file] ?? 0) }
                guard let piece = available.isEmpty ? nil : rng.pick(available) else { break }
                let height = randomHeight(piece, rng)
                let footprint = Double(piece.footprint * height / piece.height)
                let offset = side * (hw + 8 + footprint / 2 + rng.next() * 8)
                let pos = track.toWorld(s: s + footprint / 2, d: offset)
                let skip = isStartArea(s, track) || rng.next() > theme.buildings
                    || track.distanceToAxis(x: pos.x, z: pos.z) < hw + 5 + footprint * 0.55
                if !skip {
                    let e = place(piece, height: height, yaw: facingAxis(heading: pos.heading, side: side),
                                  position: [Float(pos.x), 0, Float(pos.z)])
                    root.addChild(e)
                    cullables.append((e, s + footprint / 2))
                    used[piece.entry.file, default: 0] += 1
                }
                s += footprint + 4 + rng.next() * 8
            }
        }
        return root
    }

    /// Daleki pierścień tła (np. góry w krainie Śnieg) wokół całej trasy — zawsze widoczny.
    private static func backdrop(_ track: Track, region: Region) -> Entity {
        let root = Entity()
        let pieces = LocalAssets.shared.scenery("backdrop", region: region)
        guard !pieces.isEmpty else { return root }
        var cx = 0.0, cz = 0.0, n = 0.0
        var s = 0.0
        while s < track.length { let p = track.toWorld(s: s, d: 0); cx += p.x; cz += p.z; n += 1; s += 20 }
        cx /= n; cz /= n
        var radius = 0.0
        s = 0
        while s < track.length { let p = track.toWorld(s: s, d: 0); radius = max(radius, hypot(p.x - cx, p.z - cz)); s += 20 }
        let rng = SeededRandom(seed: 77)
        let count = 8
        for i in 0..<count {
            let a = Double(i) / Double(count) * 2 * .pi + rng.next() * 0.3
            let r = radius + 260 + rng.next() * 120
            let piece = pieces[i % pieces.count]
            let e = place(piece, height: randomHeight(piece, rng), yaw: Float(-a + .pi / 2),
                          position: [Float(cx + cos(a) * r), -0.5, Float(cz + sin(a) * r)])
            root.addChild(e)
        }
        return root
    }

    private static func roadside(_ track: Track, theme: TrackTheme, region: Region) -> Entity {
        let root = Entity()
        let batch = PropBatcher()
        defer { root.addChild(batch.build()) }
        let realTrees = LocalAssets.shared.scenery("tree", region: region)
        let realBushes = LocalAssets.shared.scenery("bush", region: region)
        let rng = SeededRandom(seed: 99)
        let hw = track.halfWidth

        let trunk = MeshResource.generateCylinder(height: 2.6, radius: 0.22)
        let crown = MeshResource.generateSphere(radius: 1)
        let bark = Materials.matte(UIColor(red: 0.36, green: 0.25, blue: 0.17, alpha: 1))
        let leaves = [(0.22, 0.42, 0.18), (0.28, 0.5, 0.2), (0.18, 0.36, 0.16)]
            .map { Materials.matte(UIColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1), roughness: 0.95) }
        var s = 6.0
        while s < track.length {
            for side in [1.0, -1.0] where rng.next() < theme.trees {
                let off = side * (hw + 5 + rng.next() * 4)
                let pos = track.toWorld(s: s, d: off)
                guard track.distanceToAxis(x: pos.x, z: pos.z) > hw + 3.5 else { continue }
                // Realistyczne drzewa i krzaki (modele lokalne), jeśli są; inaczej scalone drzewa Kenney.
                if !realTrees.isEmpty {
                    let pos3 = SIMD3<Float>(Float(pos.x), 0, Float(pos.z))
                    let yaw = Float(rng.next() * 2 * .pi)
                    let piece = rng.pick(realTrees)
                    let tree = place(piece, height: randomHeight(piece, rng), yaw: yaw, position: pos3)
                    root.addChild(tree)
                    cullables.append((tree, s))
                    if !realBushes.isEmpty && rng.next() < 0.6 {
                        let bp = track.toWorld(s: s + 6, d: side * (hw + 3.5 + rng.next() * 2))
                        let bush = rng.pick(realBushes)
                        let b = place(bush, height: randomHeight(bush, rng), yaw: yaw,
                                      position: [Float(bp.x), 0, Float(bp.z)])
                        root.addChild(b)
                        cullables.append((b, s + 6))
                    }
                    continue
                }
                let treePath = rng.next() < theme.largeTrees ? "Track/treeLarge" : "Track/treeSmall"
                let treeScale = Float(5.5 + rng.next() * 2.5)
                let treeYaw = Float(rng.next() * 2 * .pi)
                let treePos = SIMD3<Float>(Float(pos.x), 0, Float(pos.z))
                if batch.add(treePath, scale: treeScale, yaw: treeYaw, position: treePos) {
                    continue
                }
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
        guard theme.lamps else { return root }
        while s < track.length {
            for side in [1.0, -1.0] {
                let pos = track.toWorld(s: s, d: side * (hw + 2.6))
                // Latarnia z modelu ma ramię w stronę −Z, więc obracamy ją o 180° względem „frontem do toru”.
                if batch.add("Track/lightPostModern", scale: 9, yaw: facingAxis(heading: pos.heading, side: side) + .pi,
                             position: [Float(pos.x), 0, Float(pos.z)]) {
                    continue
                }
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

/// Wygląd otoczenia trasy w danej krainie.
struct TrackTheme {
    var ground: UIColor
    /// 0…1 — jaka część działek przy trasie ma budynek.
    var buildings: Double
    /// 0…1 — gęstość drzew; `largeTrees` — udział dużych drzew.
    var trees: Double
    var largeTrees: Double
    var lamps: Bool

    static func of(_ region: Region) -> TrackTheme {
        switch region {
        case .city: TrackTheme(ground: UIColor(red: 0.30, green: 0.45, blue: 0.24, alpha: 1), buildings: 1, trees: 0.7, largeTrees: 0.6, lamps: true)
        case .coast: TrackTheme(ground: UIColor(red: 0.86, green: 0.78, blue: 0.56, alpha: 1), buildings: 0.12, trees: 0.45, largeTrees: 0.9, lamps: true)
        case .desert: TrackTheme(ground: UIColor(red: 0.85, green: 0.62, blue: 0.36, alpha: 1), buildings: 0, trees: 0.08, largeTrees: 0.2, lamps: false)
        case .forest: TrackTheme(ground: UIColor(red: 0.20, green: 0.36, blue: 0.17, alpha: 1), buildings: 0, trees: 1, largeTrees: 0.8, lamps: false)
        case .snow: TrackTheme(ground: UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1), buildings: 0.05, trees: 0.8, largeTrees: 0.15, lamps: true)
        }
    }
}
