import RaceCore
import RealityKit
import UIKit

/// Buduje trasę: jezdnia, linie, krawężniki, pobocze, bandy, grunt, linia startu, budynki i rekwizyty przydrożne.
@MainActor
enum TrackBuilder {
    /// Obiekty otoczenia rozstawione wzdłuż trasy (do ukrywania tych daleko od gracza) — `s` to ich miejsce na trasie.
    static var cullables: [(entity: Entity, s: Double)] = []

    /// Wysokość gruntu poza jezdnią — na niej stoją drzewa i budynki (wcześniej wisiały 30 cm nad trawą).
    static let groundY: Float = -0.3

    /// Grunt zanikający w oddali (do przesuwania środka zanikania za kamerą); `nil`, gdy grunt jest zwykły.
    static var ground: (entity: ModelEntity, material: GroundMaterial)?

    /// Rzut budynku na grunt: środek, kierunek do drogi `f`, kierunek wzdłuż fasady `r`, połowy wymiarów.
    struct Footprint {
        let center: SIMD2<Double>, f: SIMD2<Double>, r: SIMD2<Double>
        let halfWidth: Double, halfDepth: Double
        /// Odległość punktu od bryły (0 w środku).
        func distance(to p: SIMD2<Double>) -> Double {
            let v = p - center
            let dx = max(abs(simd_dot(v, r)) - halfWidth, 0), dz = max(abs(simd_dot(v, f)) - halfDepth, 0)
            return (dx * dx + dz * dz).squareRoot()
        }
    }

    /// Budynki postawione na tej trasie — drzewa nie mogą w nie wchodzić koroną.
    private static var footprints: [Footprint] = []

    static func build(_ track: Track, theme: TrackTheme = .of(.city), region: Region = .city) throws -> Entity {
        cullables = []
        footprints = []
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
        // Asfalt ze zdjęcia (CC0 Poly Haven) z mapą normalnych i chropowatości — kafel 4 m; bez plików proceduralny.
        strip(&road, -hw, hw, 0, track.length, y: 0.02, tile: 4)
        try add(road, "road", Materials.photoAsphalt() ?? Materials.roadSurfaceMaterial)

        // Linie: ciągłe przy krawędziach, przerywane między pasami. Farba 8 mm nad asfaltem — opona
        // najeżdżająca na linię nie znika w niej. UV jak jezdni (kafel 4 m): w wytarciach farby prześwituje
        // ten sam asfalt co obok. Linie omijają pas startowy (szachownica leży na tej samej wysokości).
        var lines = MeshBuilder()
        let startGap = 0.75
        for edge in [-hw + 0.3, hw - 0.3] {
            strip(&lines, edge - 0.12, edge + 0.12, startGap, track.length - startGap, y: 0.028, tile: 4)
        }
        for lane in [-hw / 3, hw / 3] {
            var s = startGap
            while s < track.length - startGap {
                strip(&lines, lane - 0.08, lane + 0.08, s, min(track.length - startGap, s + 5), y: 0.028, tile: 4)
                s += 12
            }
        }
        try add(lines, "lines", roadPaint() ?? matte(UIColor(white: 0.93, alpha: 1)))

        // Krawężniki: jedna siatka z teksturą czerwono-białych bloków po 3 m (zużyta farba, guma, kurz)
        // i mapą normalnych (zaokrąglona krawędź od jezdni, spoiny). u = 0 przy jezdni, 1 przy murze.
        var kerbs = MeshBuilder()
        // Pobocze między krawężnikiem a murem (hw + 1,2 … hw + 1,4): zasypany rowek, grunt krainy.
        var shoulder = MeshBuilder()
        for side in [1.0, -1.0] {
            var s = 0.0
            while s < track.length - 1e-6 {
                let e = min(track.length, s + track.ds)
                let v0 = Float(s / 6), v1 = Float(e / 6)
                let (dRight, dLeft) = side > 0 ? (hw, hw + 1.2) : (-hw - 1.2, -hw)
                let (uR, uL): (Float, Float) = side > 0 ? (0, 1) : (1, 0)
                kerbs.quad(p(s, dRight, 0.03), p(e, dRight, 0.03), p(e, dLeft, 0.03), p(s, dLeft, 0.03),
                           uv: [[uR, v0], [uR, v1], [uL, v1], [uL, v0]])
                let (gRight, gLeft) = side > 0 ? (hw + 1.2, hw + 1.4) : (-hw - 1.4, -hw - 1.2)
                let g0 = Float(s / 5), g1 = Float(e / 5), gu0 = Float(gRight / 5), gu1 = Float(gLeft / 5)
                shoulder.quad(p(s, gRight, 0.03), p(e, gRight, 0.03), p(e, gLeft, 0.03), p(s, gLeft, 0.03),
                              uv: [[gu0, g0], [gu0, g1], [gu1, g1], [gu1, g0]])
                s = e
            }
        }
        try add(kerbs, "kerbs", kerbMaterial() ?? matte(UIColor(red: 0.84, green: 0.16, blue: 0.16, alpha: 1)))
        let groundPhoto = Bundle.main.url(forResource: "ground-\(LocalAssets.regionKey(region))", withExtension: "jpg")
            .flatMap(SkyEnvironment.texture)
        var shoulderMaterial = groundPhoto.map { Materials.tiled($0, roughness: 1) } ?? Materials.ground(theme.ground)
        // Pobocze ciemniejsze od gruntu: kurz, guma i cień muru.
        shoulderMaterial.baseColor.tint = UIColor(white: 0.62, alpha: 1)
        try add(shoulder, "shoulder", shoulderMaterial)

        // Mur wzdłuż trasy: bryła z grubością i daszkiem, z teksturą krainy (cegła, piaskowiec, kamień, deski).
        // Kafel 2 m — tyle ma zdjęcie ściany w rzeczywistości. Grunt poza jezdnią leży niżej (groundY).
        var walls = MeshBuilder()
        let wallH = 1.2, thick = 0.35, base = Float(groundY)
        let v1 = Float((wallH - Double(groundY)) / 2)
        for side in [1.0, -1.0] {
            let inner = side * (hw + 1.4), outer = side * (hw + 1.4 + thick)
            var s = 0.0
            while s < track.length {
                let e = min(track.length, s + track.ds)
                let u0 = Float(s / 2), u1 = Float(e / 2)
                let top = Float(wallH)
                // Lico od strony drogi, tył od strony trawy, daszek — każde widoczne z zewnątrz.
                let (a, b) = side > 0 ? (inner, outer) : (outer, inner)
                walls.quad(p(s, a, base), p(e, a, base), p(e, a, top), p(s, a, top),
                           uv: [[u0, 0], [u1, 0], [u1, v1], [u0, v1]], doubleSided: true)
                walls.quad(p(e, b, base), p(s, b, base), p(s, b, top), p(e, b, top),
                           uv: [[u1, 0], [u0, 0], [u0, v1], [u1, v1]], doubleSided: true)
                let w = Float(thick / 2)
                walls.quad(p(s, inner, top), p(e, inner, top), p(e, outer, top), p(s, outer, top),
                           uv: [[u0, 0], [u1, 0], [u1, w], [u0, w]], doubleSided: true)
                s = e
            }
        }
        let regionKey = LocalAssets.regionKey(region)
        func wallTexture(_ suffix: String) -> TextureResource? {
            Bundle.main.url(forResource: "wall-\(regionKey)\(suffix)", withExtension: "jpg").flatMap(SkyEnvironment.texture)
        }
        var wallMaterial: any Material = matte(UIColor(red: 0.72, green: 0.74, blue: 0.78, alpha: 1))
        if let color = wallTexture("") {
            var m = Materials.tiled(color, roughness: 0.92)
            if let normal = wallTexture("-normal") { m.normal = .init(texture: .init(normal)) }
            wallMaterial = m
        }
        try add(walls, "walls", wallMaterial)

        // Grunt: jeden duży czworokąt z kafelkowaną teksturą — zdjęcie krainy (CC0 Poly Haven, App/Ground)
        // co 5 m, a bez niego proceduralny kolor co 6 m.
        let photo = Bundle.main.url(forResource: "ground-\(LocalAssets.regionKey(region))", withExtension: "jpg")
            .flatMap(SkyEnvironment.texture)
        var grass = MeshBuilder()
        let g: Float = 2000, reps = g / (photo == nil ? 6 : 5)
        grass.quad([-g, groundY, g], [g, groundY, g], [g, groundY, -g], [-g, groundY, -g], uv: [[0, 0], [reps, 0], [reps, reps], [0, reps]])
        ground = nil
        debugLog("trasa: jezdnia, krawężniki, bariery gotowe")
        if let photo, let fading = GroundMaterial.make(photo) {
            // Grunt zanika w oddali i przechodzi w grunt ze zdjęcia panoramy (RaceGame przesuwa krążek za kamerą).
            let e = try fading.entity(y: groundY)
            root.addChild(e)
            ground = (e, fading)
        } else {
            try add(grass, "grass", photo.map { Materials.tiled($0, roughness: 1) } ?? Materials.ground(theme.ground))
        }

        // Na starcie tylko linia na jezdni — bramy, trybuny i namioty Kenney wyglądały kanciasto.
        root.addChild(startGate(track))
        // Budynki: fasady ze zdjęć (impostory), jeśli są; krainy bez fasad zostają bez kanciastych brył.
        let library = ImpostorLibrary.shared
        let facades = library.items("building", region: region)
        let realBuildings = LocalAssets.shared.scenery("building", region: region)
        if theme.buildings > 0 && Buildings.available {
            root.addChild(pbrBuildings(track, theme: theme))
        } else if !facades.isEmpty {
            root.addChild(impostorBuildings(track, theme: theme, items: facades))
        } else if !realBuildings.isEmpty {
            root.addChild(realisticBuildings(track, theme: theme, pieces: realBuildings))
        } else if !library.has("building") {
            root.addChild(buildings(track, theme: theme))
        }
        debugLog("trasa: grunt i budynki gotowe")
        root.addChild(roadside(track, theme: theme, region: region))
        debugLog("trasa: drzewa gotowe")
        // Rekwizyty tuż za bandą (latarnie, bariery, odblaski, tablice) — rytm, który czuć przy prędkości.
        var withProps = true
        #if DEBUG || FAMILY
        // `-noRoadside` — bez rekwizytów (pomiar A/B kosztu klatki na tym samym buildzie).
        withProps = !ProcessInfo.processInfo.arguments.contains("-noRoadside")
        #endif
        if withProps { root.addChild(RoadsideProps.build(track, region: region)) }
        root.addChild(backdrop(track, region: region))
        return root
    }

    private static func startGate(_ track: Track) -> Entity {
        // Szachownica (kafel 6 × 1,5 m, zużyta farba i ślady opon) na wysokości linii — pod cieniami aut
        // (0,032) i śladami opon (0,036); linie omijają ten pas, więc nic się nie przenika.
        let hw = track.halfWidth
        var b = MeshBuilder()
        var s = -0.75
        while s < 0.75 - 1e-6 {
            let e = min(0.75, s + 0.25)
            func q(_ s: Double, _ d: Double) -> SIMD3<Float> { let w = track.toWorld(s: s, d: d); return [Float(w.x), 0.028, Float(w.z)] }
            let v0 = Float((s + 0.75) / 1.5), v1 = Float((e + 0.75) / 1.5)
            let u0 = Float(0), u1 = Float(2 * hw / 6)
            b.quad(q(s, -hw), q(e, -hw), q(e, hw), q(s, hw), uv: [[u0, v0], [u0, v1], [u1, v1], [u1, v0]])
            s = e
        }
        var material: any Material = Materials.matte(.white, roughness: 0.6)
        if let tex = Bundle.main.url(forResource: "start-line", withExtension: "jpg").flatMap(SkyEnvironment.texture) {
            var m = Materials.tiled(tex, roughness: 0.62)
            if let n = Bundle.main.url(forResource: "road-asphalt-normal", withExtension: "jpg").flatMap(SkyEnvironment.texture) {
                m.normal = .init(texture: .init(n))
            }
            material = m
        }
        guard let mesh = try? b.mesh(name: "start-line") else { return Entity() }
        return ModelEntity(mesh: mesh, materials: [material])
    }

    /// Farba linii: zdjęcie asfaltu pod wytartą farbą (App/Ground/road-paint.jpg) i normalne asfaltu —
    /// farba leży cienko i odwzorowuje kamyki.
    private static func roadPaint() -> PhysicallyBasedMaterial? {
        guard let tex = Bundle.main.url(forResource: "road-paint", withExtension: "jpg").flatMap(SkyEnvironment.texture)
        else { return nil }
        var m = Materials.tiled(tex, roughness: 0.6)
        if let n = Bundle.main.url(forResource: "road-asphalt-normal", withExtension: "jpg").flatMap(SkyEnvironment.texture) {
            m.normal = .init(texture: .init(n))
        }
        return m
    }

    private static func kerbMaterial() -> PhysicallyBasedMaterial? {
        guard let tex = Bundle.main.url(forResource: "kerb", withExtension: "jpg").flatMap(SkyEnvironment.texture)
        else { return nil }
        var m = Materials.tiled(tex, roughness: 0.66)
        if let n = Bundle.main.url(forResource: "kerb-normal", withExtension: "jpg").flatMap(SkyEnvironment.texture) {
            m.normal = .init(texture: .init(n))
        }
        return m
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

    /// Budynki z materiałów PBR: pierwsza linia — kamienice i bloki jeden przy drugim, frontem do drogi;
    /// druga linia — wyższe biurowce w odstępach, dla głębi miasta.
    private static func pbrBuildings(_ track: Track, theme: TrackTheme) -> Entity {
        var batch = Buildings.Batch()
        let rng = SeededRandom(seed: 4321)
        let hw = track.halfWidth
        func place(_ style: Buildings.Style, s: Double, offset: Double, width: Double, depth: Double, side: Double) -> Bool {
            let pos = track.toWorld(s: s + width / 2, d: side * (offset + depth / 2))
            let axis = track.toWorld(s: s + width / 2, d: 0)
            let f: SIMD2<Double> = simd_normalize(SIMD2<Double>(axis.x - pos.x, axis.z - pos.z))
            let r = SIMD2<Double>(f.y, -f.x)
            let center = SIMD2<Double>(pos.x, pos.z)
            let hd: SIMD2<Double> = f * (depth / 2 + 0.3)
            let hwv: SIMD2<Double> = r * (width / 2 + 0.3)
            let corners: [SIMD2<Double>] = [center + hd + hwv, center + hd - hwv, center - hd + hwv, center - hd - hwv,
                                            center + hwv, center - hwv]
            for c in corners where track.distanceToAxis(x: c.x, z: c.y) < hw + 4 { return false }
            footprints.append(Footprint(center: center, f: f, r: r, halfWidth: width / 2 + 0.3, halfDepth: depth / 2 + 0.3))
            let span = Double(style.floors.upperBound - style.floors.lowerBound + 1)
            let floors = style.floors.lowerBound + min(Int(rng.next() * span), style.floors.count - 1)
            batch.add(style, floors: floors, at: [Float(pos.x), groundY, Float(pos.z)],
                      facing: [Float(f.x), 0, Float(f.y)], width: Float(width), depth: Float(depth))
            return true
        }
        for side in [1.0, -1.0] {
            // Pierwsza linia: pierzeja.
            var s = 0.0
            while s < track.length {
                let width = 12 + rng.next() * 14
                if !isStartArea(s, track) && rng.next() < theme.buildings {
                    // Fronty z drobnym cofnięciem (0–1,5 m) — pierzeja nie jest idealnie równa jak od linijki.
                    _ = place(rng.pick(Buildings.street), s: s, offset: hw + 9 + rng.next() * 1.5, width: width,
                              depth: 14 + rng.next() * 6, side: side)
                }
                s += width
            }
            // Druga linia: biurowce co ~70 m, za kamienicami.
            s = rng.next() * 40
            while s < track.length {
                let width = 18 + rng.next() * 12
                if rng.next() < theme.buildings * 0.8 {
                    _ = place(rng.pick(Buildings.towers), s: s, offset: hw + 40 + rng.next() * 20, width: width, depth: width, side: side)
                }
                s += width + 40 + rng.next() * 40
            }
        }
        return batch.build()
    }

    /// Budynki z fasad-zdjęć wzdłuż trasy, frontem do niej; limit sztuk dla modeli oznaczonych `max`.
    private static func impostorBuildings(_ track: Track, theme: TrackTheme, items: [Impostor]) -> Entity {
        var batch = ImpostorBatch()
        let rng = SeededRandom(seed: 4321)
        let hw = track.halfWidth
        var used: [String: Int] = [:]
        for side in [1.0, -1.0] {
            var s = 0.0
            while s < track.length {
                let available = items.filter { ($0.def.max ?? .max) > (used[$0.def.name] ?? 0) }
                guard let item = available.isEmpty ? nil : rng.pick(available) else { break }
                let height = item.randomHeight(rng)
                let (w, d) = ImpostorBatch.buildingSize(item, height: height)
                let width = Double(w), depth = Double(d)
                // Fronty w jednej linii, budynki jeden przy drugim — ciągła pierzeja jak na prawdziwej ulicy,
                // bez widocznych boków brył między domami.
                let pos = track.toWorld(s: s + width / 2, d: side * (hw + 9 + depth / 2))
                let axis = track.toWorld(s: s + width / 2, d: 0)
                let f: SIMD2<Double> = simd_normalize(SIMD2<Double>(axis.x - pos.x, axis.z - pos.z))
                let r = SIMD2<Double>(f.y, -f.x)
                let center = SIMD2<Double>(pos.x, pos.z)
                let halfDepth: SIMD2<Double> = f * (depth / 2)
                let halfWidth: SIMD2<Double> = r * (width / 2)
                // Żaden narożnik bryły nie może wejść na trasę (także na inny jej odcinek w zakręcie).
                let corners: [SIMD2<Double>] = [
                    center + halfDepth + halfWidth, center + halfDepth - halfWidth,
                    center - halfDepth + halfWidth, center - halfDepth - halfWidth,
                    center + halfWidth, center - halfWidth,
                ]
                var tooClose = false
                for c in corners where track.distanceToAxis(x: c.x, z: c.y) < hw + 4 { tooClose = true }
                let skip = isStartArea(s, track) || rng.next() > theme.buildings || tooClose
                if !skip {
                    batch.building(item, height: height, at: [Float(pos.x), groundY, Float(pos.z)],
                                   facing: [Float(f.x), 0, Float(f.y)])
                    used[item.def.name, default: 0] += 1
                }
                s += width + 0.2
            }
        }
        return batch.build()
    }

    /// Drzewa i krzaki ze zdjęć (skrzyżowane płaszczyzny); w gęstych krainach także drugi, dalszy rząd.
    private static func impostorPlants(_ track: Track, theme: TrackTheme, region: Region) -> Entity {
        let library = ImpostorLibrary.shared
        let trees = library.items("tree", region: region)
        let bushes = library.items("bush", region: region)
        var batch = ImpostorBatch()
        let rng = SeededRandom(seed: 99)
        let hw = track.halfWidth
        func plant(_ items: [Impostor], s: Double, d: Double, clearance: Double) {
            guard !items.isEmpty else { return }
            let pos = track.toWorld(s: s, d: d)
            guard track.distanceToAxis(x: pos.x, z: pos.z) > hw + clearance else { return }
            let item = rng.pick(items)
            var height = item.randomHeight(rng)
            // Korona nie może wchodzić w budynek: przy fasadzie rośnie niższe drzewo, którego korona
            // (promień z proporcji zdjęcia) mieści się przed ścianą; za mało miejsca — bez drzewa.
            let size = item.def.size
            let crownPerHeight = max(size[0], size[2]) / size[1] / 2
            let p = SIMD2<Double>(pos.x, pos.z)
            if let near = footprints.map({ $0.distance(to: p) }).min() {
                let maxHeight = (near - 0.5) / 0.85 / crownPerHeight
                guard maxHeight >= 4.5 else { return }
                height = min(height, maxHeight)
            }
            batch.plant(item, height: height, at: [Float(pos.x), groundY, Float(pos.z)],
                        heading: pos.heading + (rng.next() - 0.5) * 0.6)
        }
        // W mieście drzewa rosną w pasie chodnika między bandą a pierzeją (fasady od hw + 9 m),
        // poza miastem dalej od drogi.
        let row = theme.buildings > 0 ? (hw + 4.2, 1.2) : (hw + 6, 4.0)
        var s = 6.0
        while s < track.length {
            for side in [1.0, -1.0] where rng.next() < theme.trees {
                plant(trees, s: s, d: side * (row.0 + rng.next() * row.1), clearance: 4)
                if rng.next() < 0.6 {
                    plant(bushes, s: s + 6, d: side * (hw + 3.5 + rng.next() * 2), clearance: 3)
                }
            }
            s += 16
        }
        if theme.trees >= 0.8 {
            s = 3
            while s < track.length {
                for side in [1.0, -1.0] where rng.next() < theme.trees {
                    plant(trees, s: s, d: side * (hw + 16 + rng.next() * 18), clearance: 12)
                }
                s += 11
            }
        }
        return batch.build()
    }

    private static func roadside(_ track: Track, theme: TrackTheme, region: Region) -> Entity {
        let root = Entity()
        if ImpostorLibrary.shared.has("tree") {
            root.addChild(impostorPlants(track, theme: theme, region: region))
            return root
        }
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

    static func of(_ region: Region) -> TrackTheme {
        switch region {
        case .city: TrackTheme(ground: UIColor(red: 0.30, green: 0.45, blue: 0.24, alpha: 1), buildings: 1, trees: 0.7, largeTrees: 0.6)
        case .coast: TrackTheme(ground: UIColor(red: 0.86, green: 0.78, blue: 0.56, alpha: 1), buildings: 0, trees: 0.45, largeTrees: 0.9)
        case .desert: TrackTheme(ground: UIColor(red: 0.85, green: 0.62, blue: 0.36, alpha: 1), buildings: 0, trees: 0.08, largeTrees: 0.2)
        case .forest: TrackTheme(ground: UIColor(red: 0.20, green: 0.36, blue: 0.17, alpha: 1), buildings: 0, trees: 1, largeTrees: 0.8)
        case .snow: TrackTheme(ground: UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1), buildings: 0, trees: 0.8, largeTrees: 0.15)
        }
    }
}
