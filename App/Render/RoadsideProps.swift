import Metal
import RaceCore
import RealityKit
import UIKit
import simd

/// Rekwizyty tuż za bandą, które dają poczucie prędkości: latarnie, bariery stalowe na murze, odblaski,
/// tyczki śnieżne, słupy z banerami i tablice kierujące (strzałki) przed ostrymi zakrętami.
///
/// Wszystko jest budowane w kodzie z gładkich brył (bryły obrotowe o 16–24 segmentach, rury, zaokrąglone
/// graniastosłupy) — latarnia czy słupek to w rzeczywistości proste kształty, a modele CC0 (Poly Haven)
/// mają tylko stylowe latarnie po 20–30 tys. trójkątów. Materiały: ocynkowana stal i jeden atlas farb
/// (znaki, odblaski, banery, klosze). Trasa jest cięta na odcinki po 100 m; odcinek to dwie siatki
/// (stal + atlas), ukrywane razem z resztą otoczenia (`TrackBuilder.cullables`).
@MainActor
enum RoadsideProps {
    /// Długość odcinka trasy scalanego w jedną siatkę na materiał.
    static let chunkLength = 100.0

    /// Co stoi przy trasie w danej krainie.
    struct Plan {
        /// Odstęp latarni (m) po jednej stronie; 0 — brak. `bothSides` — po obu stronach, naprzemiennie.
        var lampSpacing = 0.0
        var lampsBothSides = true
        var lampBanners = false
        /// Stalowa bariera (W) na murze ze słupkami co 4 m i odblaskami.
        var guardrail = false
        /// Słupki prowadzące z odblaskiem na koronie muru.
        var wallDelineators = false
        /// Tyczki śnieżne za murem.
        var snowPoles = false
        /// Wysokie słupy z banerami (naprzemiennie po obu stronach).
        var bannerPoles = false

        static func of(_ region: Region) -> Plan {
            switch region {
            case .city: Plan(lampSpacing: 24, lampsBothSides: true, lampBanners: true)
            case .coast: Plan(lampSpacing: 32, lampsBothSides: false, guardrail: true)
            case .desert: Plan(wallDelineators: true, bannerPoles: true)
            case .forest: Plan(guardrail: true)
            case .snow: Plan(guardrail: true, snowPoles: true)
            }
        }
    }

    static func build(_ track: Track, region: Region) -> Entity {
        let started = ProcessInfo.processInfo.systemUptime
        let plan = Plan.of(region)
        let hw = track.halfWidth
        let groundY = TrackBuilder.groundY
        let chunkCount = max(1, Int((track.length / chunkLength).rounded(.up)))
        var steel = [PropMesh](repeating: PropMesh(), count: chunkCount)
        var paint = [PropMesh](repeating: PropMesh(), count: chunkCount)
        func chunk(_ s: Double) -> Int {
            let w = s.truncatingRemainder(dividingBy: track.length)
            return min(chunkCount - 1, max(0, Int((w < 0 ? w + track.length : w) / chunkLength)))
        }
        let atlas = PropAtlas.self
        var placedCount = 0

        /// Układ w punkcie (s, d): X — w stronę jezdni, Y — w górę, Z = X × Y (wzdłuż trasy); początek na gruncie.
        func roadFrame(_ s: Double, _ d: Double, y: Float = groundY) -> PropMesh.Frame {
            let w = track.toWorld(s: s, d: d)
            let left = SIMD3<Float>(Float(cos(w.heading)), 0, Float(-sin(w.heading)))
            let x = d > 0 ? -left : left
            let up = SIMD3<Float>(0, 1, 0)
            return PropMesh.Frame(origin: [Float(w.x), y, Float(w.z)], x: x, y: up, z: simd_cross(x, up))
        }
        /// Układ tablicy: Z — w stronę nadjeżdżającego kierowcy (lekko ku jezdni), X — jego prawa ręka.
        func facingFrame(_ s: Double, _ d: Double, y: Float, towardRoad: Float = 0.25) -> PropMesh.Frame {
            let w = track.toWorld(s: s, d: d)
            let forward = SIMD3<Float>(Float(sin(w.heading)), 0, Float(cos(w.heading)))
            let left = SIMD3<Float>(Float(cos(w.heading)), 0, Float(-sin(w.heading)))
            let road = d > 0 ? -left : left
            let z = simd_normalize(-forward + road * towardRoad)
            let up = SIMD3<Float>(0, 1, 0)
            return PropMesh.Frame(origin: [Float(w.x), y, Float(w.z)], x: simd_cross(up, z), y: up, z: z)
        }

        // MARK: Tablice kierujące przed ostrymi zakrętami — po zewnętrznej stronie łuku.
        var chevronSpots: [(s: Double, side: Double)] = []
        do {
            let tight = 1.0 / 85
            var s = 0.0
            var runStart: Double?
            var runSign = 0.0
            var runs: [(Double, Double, Double)] = []
            while s <= track.length {
                let k = track.sample(at: s).curvature
                if abs(k) > tight {
                    if runStart == nil { runStart = s; runSign = k > 0 ? 1 : -1 }
                } else if let r = runStart {
                    runs.append((r, s, runSign)); runStart = nil
                }
                s += 2
            }
            if let r = runStart { runs.append((r, track.length, runSign)) }
            for (a, b, sign) in runs where b - a > 8 {
                // Zakręt w lewo (krzywizna > 0) → tablice po prawej (d < 0), strzałki w lewo.
                let side = -sign
                var t = a - 30
                while t < b - 4 {
                    chevronSpots.append((t, side))
                    t += 14
                }
            }
        }
        func nearChevron(_ s: Double, _ side: Double, _ gap: Double = 4) -> Bool {
            chevronSpots.contains { $0.side == side && abs(wrapDelta($0.s, s, track.length)) < gap }
        }
        for spot in chevronSpots {
            let d = spot.side * (hw + 2.2)
            let c = chunk(spot.s)
            let post = roadFrame(spot.s, d)
            steel[c].lathe(PropShapes.post(height: 2.25, radius: 0.035), segments: 16, frame: post, uv: .steel(height: 2.25))
            // Tablica 0,6 × 0,75 m na wysokości 1,3–2,05 m nad jezdnią (ponad murem 1,2 m), 5 cm przed słupkiem.
            var board = facingFrame(spot.s, d, y: 1.675)
            board.origin += board.zAxis * 0.05
            let leftTurn = spot.side < 0
            paint[c].board(width: 0.6, height: 0.75, thickness: 0.018, corner: 0.03, frame: board,
                           front: leftTurn ? atlas.chevron.mirrored : atlas.chevron, back: atlas.signBack)
            placedCount += 1
        }

        // MARK: Latarnie (miasto, wybrzeże) — wysięgnik nad krawędź jezdni, w mieście z banerami.
        if plan.lampSpacing > 0 {
            for side in plan.lampsBothSides ? [1.0, -1.0] : [1.0] {
                var s = side > 0 ? 6.0 : 6 + plan.lampSpacing / 2
                var n = 0
                while s < track.length - 6 {
                    defer { s += plan.lampSpacing; n += 1 }
                    if nearChevron(s, side) { continue }
                    let c = chunk(s)
                    let frame = roadFrame(s, side * (hw + 2.1))
                    PropShapes.streetLamp(&steel[c], &paint[c], frame: frame, height: 8.6, reach: 2.6)
                    if plan.lampBanners {
                        PropShapes.banner(&steel[c], &paint[c], frame: frame, y0: 4.3, y1: 6.1, width: 0.6,
                                          design: atlas.banners[(n + (side > 0 ? 0 : 1)) % atlas.banners.count])
                    }
                    placedCount += 1
                }
            }
        }

        // MARK: Słupy z banerami (pustynia) — co 20 m, naprzemiennie po obu stronach.
        if plan.bannerPoles {
            var s = 10.0, n = 0
            while s < track.length - 6 {
                defer { s += 20; n += 1 }
                let side: Double = n % 2 == 0 ? 1 : -1
                if nearChevron(s, side) { continue }
                let c = chunk(s)
                let frame = roadFrame(s, side * (hw + 2.1))
                steel[c].lathe(PropShapes.pole(height: 6.6, base: 0.1, top: 0.055), segments: 20, frame: frame,
                               uv: .steel(height: 6.6))
                PropShapes.banner(&steel[c], &paint[c], frame: frame, y0: 3.3, y1: 6.0, width: 0.8,
                                  design: atlas.banners[n / 2 % atlas.banners.count])
                placedCount += 1
            }
        }

        // MARK: Słupki prowadzące na koronie muru (pustynia) — biały słupek z czarnym pasem i odblaskiem.
        if plan.wallDelineators {
            for side in [1.0, -1.0] {
                var s = side > 0 ? 4.0 : 12.0
                while s < track.length - 2 {
                    defer { s += 16 }
                    if nearChevron(s, side, 2) { continue }
                    let c = chunk(s)
                    let frame = roadFrame(s, side * (hw + 1.575), y: 1.2)
                    paint[c].prism(halfX: 0.05, halfZ: 0.03, corner: 0.022, y0: 0, y1: 0.5, frame: frame,
                                   side: .rect(atlas.delineator), cap: .rect(atlas.delineator.sub(v0: 0.97, v1: 1)))
                    var plate = facingFrame(s, side * (hw + 1.575), y: 1.2 + 0.36, towardRoad: 0)
                    plate.origin += plate.zAxis * 0.031
                    paint[c].board(width: 0.05, height: 0.09, thickness: 0.006, corner: 0.008, frame: plate,
                                   front: atlas.reflectorAmber, back: atlas.reflectorAmber)
                    placedCount += 1
                }
            }
        }

        // MARK: Tyczki śnieżne — pomarańczowo-czarne, za murem, sterczą 1,4 m ponad koroną.
        if plan.snowPoles {
            for side in [1.0, -1.0] {
                var s = side > 0 ? 3.0 : 10.5
                while s < track.length - 2 {
                    defer { s += 15 }
                    if nearChevron(s, side, 2) { continue }
                    let c = chunk(s)
                    let frame = roadFrame(s, side * (hw + 1.95))
                    paint[c].lathe(PropShapes.post(height: 2.9, radius: 0.024), segments: 12, frame: frame,
                                   uv: .rect(atlas.snowPole))
                    placedCount += 1
                }
            }
        }

        // MARK: Bariera stalowa (W) na murze: słupki co 4 m na koronie, przekładki, taśma i odblaski co 16 m.
        if plan.guardrail {
            for side in [1.0, -1.0] {
                for c in 0..<chunkCount {
                    let s0 = Double(c) * chunkLength, s1 = min(track.length, s0 + chunkLength)
                    steel[c].wBeam(track, side: side, s0: s0, s1: s1, front: hw + 1.45, y0: 1.29)
                }
                var s = 2.0, n = 0
                while s < track.length - 1 {
                    defer { s += 4; n += 1 }
                    let c = chunk(s)
                    let post = roadFrame(s, side * (hw + 1.62), y: 1.2)
                    steel[c].prism(halfX: 0.04, halfZ: 0.06, corner: 0.012, y0: 0, y1: 0.5, frame: post,
                                   side: .steel(height: 0.5), cap: .steel(height: 0.1))
                    let spacer = roadFrame(s, side * (hw + 1.556), y: 1.2)
                    steel[c].prism(halfX: 0.024, halfZ: 0.05, corner: 0.008, y0: 0.15, y1: 0.38, frame: spacer,
                                   side: .steel(height: 0.25), cap: .steel(height: 0.1))
                    if n % 4 == 0 {
                        // Odblask w środkowym rowku taśmy (lico w tym miejscu jest 8,5 cm dalej od jezdni).
                        let plate = facingFrame(s, side * (hw + 1.505), y: 1.445, towardRoad: 0)
                        paint[c].board(width: 0.08, height: 0.1, thickness: 0.006, corner: 0.012, frame: plate,
                                       front: atlas.reflectorAmber, back: atlas.signBack)
                    }
                    placedCount += 1
                }
            }
        }

        // MARK: Scalanie: na odcinek jedna siatka stali i jedna atlasu.
        let root = Entity()
        root.name = "roadside-props"
        var meshes = 0
        for c in 0..<chunkCount where !steel[c].isEmpty || !paint[c].isEmpty {
            let e = Entity()
            if !steel[c].isEmpty, let m = try? steel[c].mesh(name: "props-steel-\(c)") {
                e.addChild(ModelEntity(mesh: m, materials: [PropAtlas.steelMaterial])); meshes += 1
            }
            if !paint[c].isEmpty {
                do {
                    let m = try paint[c].mesh(name: "props-paint-\(c)")
                    e.addChild(ModelEntity(mesh: m, materials: [PropAtlas.paintMaterial])); meshes += 1
                } catch {
                    debugLog("rekwizyty: BŁĄD siatki farb \(c): \(error)")
                }
            }
            root.addChild(e)
            // Odcinek pokazujemy, zanim jego początek wejdzie w zasięg widzenia (miejsce = początek + 25 m).
            TrackBuilder.cullables.append((e, Double(c) * chunkLength + 25))
        }
        let triangles = (steel + paint).reduce(0) { $0 + $1.triangleCount }
        debugLog("rekwizyty: odcinków \(chunkCount), wierzchołki farb \(paint.map(\.vertexCount).reduce(0, +))")
        debugLog(String(format: "rekwizyty: %d sztuk, %d tablic, %d siatek, %d tys. trójkątów, %.0f ms",
                        placedCount, chevronSpots.count, meshes, triangles / 1000,
                        (ProcessInfo.processInfo.systemUptime - started) * 1000))
        return root
    }
}

// MARK: - Kształty

@MainActor
enum PropShapes {
    /// Profil słupka (r, y): stopa z fazą, równa średnica, zaokrąglony wierzch.
    static func post(height: Float, radius r: Float) -> [SIMD2<Float>] {
        [[0, 0], [r * 1.25, 0], [r * 1.25, 0], [r * 1.25, 0.03], [r, 0.06],
         [r, height - r * 0.6], [r * 0.8, height - r * 0.15], [r * 0.4, height], [0, height]]
    }

    /// Profil zwężającego się słupa (latarnia, maszt): cokół, trzon stożkowy, kapelusz.
    static func pole(height: Float, base: Float, top: Float) -> [SIMD2<Float>] {
        let b = base * 1.7
        return [[0, 0], [b, 0], [b, 0], [b, 0.05], [b * 0.92, 0.12], [base * 1.25, 0.5], [base * 1.25, 0.62],
                [base * 1.25, 0.62], [base * 1.05, 0.66], [base, 0.75], [top, height - 0.05],
                [top * 0.9, height - 0.01], [top * 0.5, height], [0, height]]
    }

    /// Latarnia z łukowym wysięgnikiem nad jezdnię i płaską oprawą z kloszem od spodu.
    /// Układ `frame`: X — w stronę jezdni, Y — w górę, początek na gruncie u stopy słupa.
    static func streetLamp(_ steel: inout PropMesh, _ paint: inout PropMesh, frame: PropMesh.Frame,
                           height h: Float, reach: Float) {
        steel.lathe(pole(height: h, base: 0.1, top: 0.06), segments: 20, frame: frame, uv: .steel(height: h))
        // Wysięgnik: krzywa Béziera od wnętrza słupa w górę i łukiem nad jezdnię.
        let p0 = SIMD3<Float>(0, h - 0.4, 0), p1 = SIMD3<Float>(0, h + 0.35, 0)
        let p2 = SIMD3<Float>(reach * 0.25, h + 0.48, 0), p3 = SIMD3<Float>(reach, h + 0.42, 0)
        let path: [SIMD3<Float>] = (0...14).map { i in
            let t = Float(i) / 14, u = 1 - t
            return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
        }
        steel.tube(path, radius: 0.045, segments: 12, frame: frame, uv: .steel(height: reach))
        // Oprawa: spłaszczona bryła obrotowa o osi wzdłuż wysięgnika (X), długość 0,8 m.
        let housingAt = SIMD3<Float>(reach - 0.12, h + 0.40, 0)
        let housing = frame.child(origin: housingAt, x: [0, 0.42, 0], y: [1, 0, 0], z: [0, 0, 1])
        let profile: [SIMD2<Float>] = [[0, 0], [0.08, 0.015], [0.14, 0.08], [0.17, 0.25], [0.17, 0.5],
                                       [0.15, 0.68], [0.1, 0.77], [0, 0.8]]
        steel.lathe(profile, segments: 24, frame: housing, uv: .steel(height: 0.8))
        // Klosz: płaski owal pod oprawą (część atlasu ze słabym świeceniem).
        let lensAt = housingAt + SIMD3<Float>(0.4, -0.17 * 0.42 + 0.004, 0)
        let lens = frame.child(origin: lensAt, x: [2.0, 0, 0], y: [0, 1, 0], z: [0, 0, 0.85])
        paint.lathe([[0, -0.012], [0.13, -0.012], [0.13, -0.012], [0.135, 0], [0.12, 0.01], [0, 0.01]],
                    segments: 24, frame: lens, uv: .rect(PropAtlas.lens))
    }

    /// Baner na dwóch wysięgnikach przy słupie, prostopadły do krawędzi jezdni (widać go z nadjeżdżającego auta).
    static func banner(_ steel: inout PropMesh, _ paint: inout PropMesh, frame: PropMesh.Frame,
                       y0: Float, y1: Float, width: Float, design: PropAtlas.Rect) {
        for y in [y0 - 0.03, y1 + 0.03] {
            steel.tube([[0, y, 0], [width + 0.16, y, 0]], radius: 0.018, segments: 10, frame: frame,
                       uv: .steel(height: width))
        }
        paint.cloth(x0: 0.13, x1: 0.13 + width, y0: y0, y1: y1, frame: frame, design: design)
    }
}

// MARK: - Atlas farb i materiały

@MainActor
enum PropAtlas {
    /// Prostokąt w atlasie (UV 0…1); `map(u, v)` — v rośnie w górę rysunku.
    struct Rect {
        var u0: Float, v0: Float, u1: Float, v1: Float
        func map(_ u: Float, _ v: Float) -> SIMD2<Float> { [u0 + (u1 - u0) * u, v0 + (v1 - v0) * v] }
        var mirrored: Rect { Rect(u0: u1, v0: v0, u1: u0, v1: v1) }
        func sub(v0 a: Float, v1 b: Float) -> Rect { Rect(u0: u0, v0: v0 + (v1 - v0) * a, u1: u1, v1: v0 + (v1 - v0) * b) }
    }

    static let size = 1024
    /// Prostokąt w pikselach (układ CG: y w górę) → UV, z marginesem przeciw przeciekaniu sąsiadów w mipmapach.
    private static func px(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Rect {
        let s = Float(size), m: Float = 3
        // Układ CG (y w górę) pokrywa się z UV RealityKit (v = 0 na dole obrazu).
        return Rect(u0: (Float(x0) + m) / s, v0: (Float(y0) + m) / s, u1: (Float(x1) - m) / s, v1: (Float(y1) - m) / s)
    }

    static let chevron = px(0, 400, 480, 1000)
    static let signBack = px(480, 400, 640, 1000)
    static let delineator = px(640, 400, 768, 1000)
    static let snowPole = px(768, 400, 1024, 880)
    static let reflectorAmber = px(768, 896, 896, 1024)
    static let lens = px(896, 896, 1024, 1024)
    static let banners = [px(0, 0, 256, 400), px(256, 0, 512, 400), px(512, 0, 768, 400)]

    /// Atlas koloru — rysowany w kodzie, bez plików.
    static let image: CGImage = {
        let s = CGFloat(size)
        func r(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> CGRect {
            CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
        let color = Materials.image(width: size, height: size) { g in
            g.setFillColor(UIColor(white: 0.5, alpha: 1).cgColor)
            g.fill(CGRect(x: 0, y: 0, width: s, height: s))

            // Tablica U-3: czerwone pole, białe strzałki „>”, biała obwódka.
            let cr = r(0, 400, 480, 1000)
            g.setFillColor(UIColor(white: 0.93, alpha: 1).cgColor)
            g.fill(cr)
            g.setFillColor(UIColor(red: 0.74, green: 0.07, blue: 0.08, alpha: 1).cgColor)
            g.fill(cr.insetBy(dx: 18, dy: 18))
            g.setFillColor(UIColor(white: 0.95, alpha: 1).cgColor)
            for k in 0..<2 {
                let x = cr.minX + 60 + CGFloat(k) * 150
                let mid = cr.midY, half: CGFloat = 230, thick: CGFloat = 80, tip: CGFloat = 130
                g.beginPath()
                g.move(to: CGPoint(x: x, y: mid + half))
                g.addLine(to: CGPoint(x: x + thick, y: mid + half))
                g.addLine(to: CGPoint(x: x + thick + tip, y: mid))
                g.addLine(to: CGPoint(x: x + thick, y: mid - half))
                g.addLine(to: CGPoint(x: x, y: mid - half))
                g.addLine(to: CGPoint(x: x + tip, y: mid))
                g.closePath()
                g.fillPath()
            }
            // Tył tablicy: szara blacha ocynkowana.
            g.setFillColor(UIColor(white: 0.62, alpha: 1).cgColor)
            g.fill(r(480, 400, 640, 1000))
            // Słupek prowadzący: biały z czarnym pasem w górnej części.
            g.setFillColor(UIColor(white: 0.92, alpha: 1).cgColor)
            g.fill(r(640, 400, 768, 1000))
            g.setFillColor(UIColor(white: 0.07, alpha: 1).cgColor)
            g.fill(CGRect(x: 640, y: 400 + 600 * 0.6, width: 128, height: 600 * 0.3))
            // Tyczka śnieżna: 12 pasów pomarańczowo-czarnych.
            for k in 0..<12 {
                g.setFillColor((k % 2 == 0 ? UIColor(red: 0.98, green: 0.42, blue: 0.04, alpha: 1)
                                           : UIColor(white: 0.06, alpha: 1)).cgColor)
                g.fill(CGRect(x: 768, y: 400 + CGFloat(k) * 40, width: 256, height: 40))
            }
            // Odblask: bursztynowy, z siatką pryzmatów.
            g.setFillColor(UIColor(red: 1, green: 0.62, blue: 0.08, alpha: 1).cgColor)
            g.fill(r(768, 896, 896, 1024))
            g.setStrokeColor(UIColor(red: 0.75, green: 0.4, blue: 0.02, alpha: 1).cgColor)
            g.setLineWidth(2)
            for k in stride(from: 776, to: 896, by: 12) {
                g.stroke(CGRect(x: CGFloat(k), y: 900, width: 0, height: 120))
                g.stroke(CGRect(x: 768, y: CGFloat(k + 128), width: 128, height: 0))
            }
            // Klosz: mleczne szkło.
            g.setFillColor(UIColor(red: 0.96, green: 0.95, blue: 0.9, alpha: 1).cgColor)
            g.fill(r(896, 896, 1024, 1024))

            // Banery (bez napisów — z drugiej strony widać lustrzane odbicie): tkanina w barwach wyścigu.
            let designs: [(UIColor, UIColor, UIColor)] = [
                (UIColor(red: 0.05, green: 0.16, blue: 0.48, alpha: 1), UIColor(red: 0.1, green: 0.42, blue: 0.85, alpha: 1), .white),
                (UIColor(red: 0.72, green: 0.06, blue: 0.08, alpha: 1), UIColor(red: 0.98, green: 0.45, blue: 0.08, alpha: 1), .white),
                (UIColor(red: 0.98, green: 0.78, blue: 0.1, alpha: 1), UIColor(red: 0.95, green: 0.55, blue: 0.05, alpha: 1), UIColor(white: 0.08, alpha: 1)),
            ]
            for (i, d) in designs.enumerated() {
                let br = r(i * 256, 0, i * 256 + 256, 400)
                g.saveGState()
                g.clip(to: br)
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [d.0.cgColor, d.1.cgColor] as CFArray,
                                      locations: [0, 1])!
                g.drawLinearGradient(grad, start: CGPoint(x: br.minX, y: br.minY), end: CGPoint(x: br.maxX, y: br.maxY), options: [])
                // Ukośne pasy „prędkości”.
                g.setFillColor(d.2.withAlphaComponent(0.9).cgColor)
                for k in 0..<3 {
                    let y = br.minY + 120 + CGFloat(k) * 46
                    g.beginPath()
                    g.move(to: CGPoint(x: br.minX, y: y))
                    g.addLine(to: CGPoint(x: br.maxX, y: y + 90))
                    g.addLine(to: CGPoint(x: br.maxX, y: y + 90 + CGFloat(24 - k * 6)))
                    g.addLine(to: CGPoint(x: br.minX, y: y + CGFloat(24 - k * 6)))
                    g.closePath()
                    g.fillPath()
                }
                // Szachownica u góry i u dołu.
                for row in 0..<2 {
                    for col in 0..<8 where (col + row) % 2 == 0 {
                        g.setFillColor(UIColor(white: 0.05, alpha: 1).cgColor)
                        g.fill(CGRect(x: br.minX + CGFloat(col) * 32, y: br.maxY - 64 + CGFloat(row) * 32, width: 32, height: 32))
                        g.fill(CGRect(x: br.minX + CGFloat(col) * 32, y: br.minY + CGFloat(row) * 32, width: 32, height: 32))
                    }
                }
                for row in 0..<2 {
                    for col in 0..<8 where (col + row) % 2 == 1 {
                        g.setFillColor(UIColor(white: 0.95, alpha: 1).cgColor)
                        g.fill(CGRect(x: br.minX + CGFloat(col) * 32, y: br.maxY - 64 + CGFloat(row) * 32, width: 32, height: 32))
                        g.fill(CGRect(x: br.minX + CGFloat(col) * 32, y: br.minY + CGFloat(row) * 32, width: 32, height: 32))
                    }
                }
                g.restoreGState()
            }
            // Brud i ziarno: drobne plamki na całym atlasie (farba na zewnątrz nigdy nie jest idealnie równa).
            let rng = SeededRandom(seed: 515)
            for _ in 0..<26000 {
                let v = CGFloat(rng.next())
                g.setFillColor(UIColor(white: v < 0.5 ? 0 : 1, alpha: 0.035 + 0.05 * CGFloat(rng.next())).cgColor)
                let w = 1 + 3 * CGFloat(rng.next())
                g.fill(CGRect(x: CGFloat(rng.next()) * s, y: CGFloat(rng.next()) * s, width: w, height: w))
            }
            // Zacieki brudu od dołu na tablicy i słupku.
            for rect in [r(0, 400, 480, 1000), r(640, 400, 768, 1000)] {
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [UIColor(red: 0.3, green: 0.26, blue: 0.2, alpha: 0.28).cgColor,
                                               UIColor(red: 0.3, green: 0.26, blue: 0.2, alpha: 0).cgColor] as CFArray,
                                      locations: [0, 1])!
                g.saveGState(); g.clip(to: rect)
                g.drawLinearGradient(grad, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.minY + rect.height * 0.35), options: [])
                g.restoreGState()
            }
        }
        return color
    }()

    private static func sampler(repeat rep: Bool) -> MaterialParameters.Texture.Sampler {
        let s = MTLSamplerDescriptor()
        s.sAddressMode = rep ? .repeat : .clampToEdge
        s.tAddressMode = rep ? .repeat : .clampToEdge
        s.minFilter = .linear
        s.magFilter = .linear
        s.mipFilter = .linear
        s.maxAnisotropy = 8
        return .init(s)
    }

    /// Farby: atlas z lekkim połyskiem.
    static let paintMaterial: PhysicallyBasedMaterial = {
        var m = PhysicallyBasedMaterial()
        m.roughness = 0.5
        m.metallic = 0.0
        do {
            let tex = try Materials.texture(image)
            m.baseColor = .init(tint: .white, texture: .init(tex, sampler: sampler(repeat: false)))
        } catch {
            debugLog("rekwizyty: BŁĄD tekstury atlasu: \(error)")
        }
        return m
    }()

    /// Stal ocynkowana: zdjęciowa tekstura PBR (ambientCG Metal049B, CC0 — kolor ze smugami brudu,
    /// normalne, chropowatość) w App/Ground/props-steel*.jpg; bez plików — plamista faktura z kodu.
    static let steelMaterial: PhysicallyBasedMaterial = {
        var m = PhysicallyBasedMaterial()
        // Stary, zmatowiały ocynk: częściowo metal, mocno chropowaty. Profil W odbijał wyraźnie niebo
        // (górne pochyłości) i piasek (dolne) — niebiesko-żółte pasy wyglądały sztucznie.
        m.metallic = 0.75
        m.roughness = 0.75
        func tex(_ name: String) -> TextureResource? {
            Bundle.main.url(forResource: name, withExtension: "jpg").flatMap(SkyEnvironment.texture)
        }
        if let color = tex("props-steel") {
            // Cynk jest jaśniejszy i bardziej matowy niż wypolerowana stal ze zdjęcia.
            m.baseColor = .init(tint: UIColor(white: 0.9, alpha: 1), texture: .init(color, sampler: sampler(repeat: true)))
            if let n = tex("props-steel-normal") { m.normal = .init(texture: .init(n, sampler: sampler(repeat: true))) }
            if let r = tex("props-steel-rough") {
                m.roughness = .init(scale: 2.2, texture: .init(r, sampler: sampler(repeat: true)))
            }
            return m
        }
        let img = Materials.image(width: 256, height: 256) { g in
            g.setFillColor(UIColor(white: 0.74, alpha: 1).cgColor)
            g.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            let rng = SeededRandom(seed: 808)
            // Cętki (krystality cynku) i ciemniejsze zacieki biegnące w dół.
            for _ in 0..<1400 {
                let v = 0.62 + 0.2 * CGFloat(rng.next())
                g.setFillColor(UIColor(white: v, alpha: 0.35).cgColor)
                let w = 3 + 9 * CGFloat(rng.next())
                // Kafelkowanie: plamka przy krawędzi powtarza się z drugiej strony.
                let x = CGFloat(rng.next()) * 256, y = CGFloat(rng.next()) * 256
                for ox in [-256.0, 0, 256] as [CGFloat] { for oy in [-256.0, 0, 256] as [CGFloat] {
                    g.fillEllipse(in: CGRect(x: x + ox, y: y + oy, width: w, height: w * (0.6 + 0.6 * CGFloat(rng.next()))))
                } }
            }
            for _ in 0..<60 {
                g.setFillColor(UIColor(red: 0.45, green: 0.43, blue: 0.4, alpha: 0.12).cgColor)
                let x = CGFloat(rng.next()) * 256
                g.fill(CGRect(x: x, y: 0, width: 1 + 3 * CGFloat(rng.next()), height: 256))
            }
        }
        if let tex = try? Materials.texture(img) {
            m.baseColor = .init(tint: .white, texture: .init(tex, sampler: sampler(repeat: true)))
        }
        return m
    }()
}

// MARK: - Siatka z gładkimi normalnymi

/// Siatka rekwizytów: wierzchołki z normalnymi i UV; kolejność trójkątów dobierana tak, żeby ściany
/// patrzyły w stronę normalnych (bryła widoczna z zewnątrz, także po przekształceniach z odbiciem).
struct PropMesh {
    private(set) var positions: [SIMD3<Float>] = []
    private(set) var normals: [SIMD3<Float>] = []
    private(set) var uvs: [SIMD2<Float>] = []
    private(set) var indices: [UInt32] = []
    var isEmpty: Bool { indices.isEmpty }
    var triangleCount: Int { indices.count / 3 }
    var vertexCount: Int { positions.count }

    /// Układ współrzędnych rekwizytu: osie mogą mieć długość ≠ 1 (skalowanie).
    struct Frame {
        var origin: SIMD3<Float>
        var x: SIMD3<Float>, y: SIMD3<Float>, z: SIMD3<Float>
        var zAxis: SIMD3<Float> { simd_normalize(z) }
        private var basis: simd_float3x3 { simd_float3x3(columns: (x, y, z)) }
        func point(_ p: SIMD3<Float>) -> SIMD3<Float> { origin + basis * p }
        func normal(_ n: SIMD3<Float>) -> SIMD3<Float> {
            let v = basis.inverse.transpose * n
            return simd_length(v) > 1e-9 ? simd_normalize(v) : [0, 1, 0]
        }
        /// Układ zagnieżdżony: początek i osie podane we współrzędnych tego układu.
        func child(origin o: SIMD3<Float>, x cx: SIMD3<Float>, y cy: SIMD3<Float>, z cz: SIMD3<Float>) -> Frame {
            Frame(origin: point(o), x: basis * cx, y: basis * cy, z: basis * cz)
        }
    }

    /// Odwzorowanie UV bryły: prostokąt atlasu albo kafelkowana stal (v w metrach / 2).
    enum UVMode {
        case rect(PropAtlas.Rect)
        case steel(height: Float)
        func map(_ u: Float, _ v: Float) -> SIMD2<Float> {
            switch self {
            case .rect(let r): r.map(u, v)
            case .steel(let h): [u * 0.5, v * h * 0.5]
            }
        }
    }

    private mutating func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float>) -> UInt32 {
        positions.append(p); normals.append(n); uvs.append(uv)
        return UInt32(positions.count - 1)
    }

    /// Trójkąt skierowany zgodnie z normalnymi wierzchołków.
    private mutating func tri(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        let pa = positions[Int(a)], pb = positions[Int(b)], pc = positions[Int(c)]
        let face = simd_cross(pb - pa, pc - pa)
        let n = normals[Int(a)] + normals[Int(b)] + normals[Int(c)]
        if simd_length_squared(face) < 1e-14 { return }
        if simd_dot(face, n) >= 0 { indices += [a, b, c] } else { indices += [a, c, b] }
    }

    /// Bryła obrotowa: profil (promień, wysokość) od dołu do góry wokół osi Y układu `frame`.
    /// Powtórzony punkt profilu daje ostrą krawędź (np. przy denku).
    mutating func lathe(_ profile: [SIMD2<Float>], segments: Int, frame: Frame, uv: UVMode) {
        guard profile.count > 1 else { return }
        let yMin = profile.map(\.y).min()!, yMax = profile.map(\.y).max()!
        let span = max(yMax - yMin, 1e-4)
        // Normalna profilu w punkcie: średnia normalnych sąsiednich odcinków o niezerowej długości.
        func segNormal(_ i: Int) -> SIMD2<Float>? {
            let d = profile[i + 1] - profile[i]
            guard simd_length(d) > 1e-6 else { return nil }
            return simd_normalize(SIMD2<Float>(d.y, -d.x))
        }
        // Przy powtórzonym punkcie jeden z sąsiednich odcinków ma długość 0 — zostaje normalna drugiego.
        let pn: [SIMD2<Float>] = profile.indices.map { i in
            let a = i > 0 ? segNormal(i - 1) : nil
            let b = i < profile.count - 1 ? segNormal(i) : nil
            if let a, let b { return simd_normalize(a + b) }
            return a ?? b ?? [1, 0]
        }
        let base = UInt32(positions.count)
        let ring = segments + 1
        for (i, p) in profile.enumerated() {
            for j in 0...segments {
                let t = Float(j) / Float(segments) * 2 * .pi
                let c = cos(t), s = sin(t)
                let local = SIMD3<Float>(p.x * c, p.y, p.x * s)
                let nl = SIMD3<Float>(pn[i].x * c, pn[i].y, pn[i].x * s)
                _ = vertex(frame.point(local), frame.normal(nl), uv.map(Float(j) / Float(segments), (p.y - yMin) / span))
            }
        }
        for i in 0..<(profile.count - 1) {
            if simd_length(profile[i + 1] - profile[i]) < 1e-6 { continue }
            for j in 0..<segments {
                let a = base + UInt32(i * ring + j), b = a + 1
                let c = base + UInt32((i + 1) * ring + j), d = c + 1
                tri(a, c, d); tri(a, d, b)
            }
        }
    }

    /// Rura o stałym promieniu wzdłuż łamanej (we współrzędnych `frame`), bez denek.
    mutating func tube(_ path: [SIMD3<Float>], radius: Float, segments: Int, frame: Frame, uv: UVMode) {
        guard path.count > 1 else { return }
        let base = UInt32(positions.count)
        // Ramka przenoszona równolegle — przekrój nie skręca się na łuku.
        var t0 = simd_normalize(path[1] - path[0])
        var n0 = abs(t0.y) < 0.9 ? simd_normalize(simd_cross(t0, [0, 1, 0])) : simd_normalize(simd_cross(t0, [1, 0, 0]))
        var length: Float = 0
        for (i, p) in path.enumerated() {
            if i > 0 { length += simd_distance(p, path[i - 1]) }
            let t = i == 0 ? t0 : (i == path.count - 1 ? simd_normalize(p - path[i - 1])
                                                       : simd_normalize(path[i + 1] - path[i - 1]))
            // Przeniesienie normalnej na nową styczną.
            n0 = simd_normalize(n0 - simd_dot(n0, t) * t)
            t0 = t
            let b0 = simd_cross(t, n0)
            for j in 0...segments {
                let a = Float(j) / Float(segments) * 2 * .pi
                let dir = n0 * cos(a) + b0 * sin(a)
                _ = vertex(frame.point(p + dir * radius), frame.normal(dir), uv.map(Float(j) / Float(segments), length))
            }
        }
        let ring = UInt32(segments + 1)
        for i in 0..<UInt32(path.count - 1) {
            for j in 0..<UInt32(segments) {
                let a = base + i * ring + j, b = a + 1, c = a + ring, d = c + 1
                tri(a, c, d); tri(a, d, b)
            }
        }
    }

    /// Zaokrąglony graniastosłup: przekrój — prostokąt 2·halfX × 2·halfZ z zaokrąglonymi narożnikami
    /// w płaszczyźnie XZ, wyciągnięty wzdłuż Y od y0 do y1, z płaskimi denkami.
    mutating func prism(halfX: Float, halfZ: Float, corner: Float, y0: Float, y1: Float, frame: Frame,
                        side: UVMode, cap: UVMode, arc: Int = 4) {
        // Obwód: cztery łuki po `arc` odcinków.
        var ring: [(p: SIMD2<Float>, n: SIMD2<Float>)] = []
        let centers: [SIMD2<Float>] = [[halfX - corner, halfZ - corner], [-(halfX - corner), halfZ - corner],
                                       [-(halfX - corner), -(halfZ - corner)], [halfX - corner, -(halfZ - corner)]]
        for (k, c) in centers.enumerated() {
            for i in 0...arc {
                let a = (Float(k) + Float(i) / Float(arc)) * .pi / 2
                let n = SIMD2<Float>(cos(a), sin(a))
                ring.append((c + n * corner, n))
            }
        }
        let count = ring.count
        var perim: [Float] = [0]
        for i in 1...count { perim.append(perim[i - 1] + simd_distance(ring[i % count].p, ring[i - 1].p)) }
        let total = perim[count]
        let base = UInt32(positions.count)
        for (yi, y) in [y0, y1].enumerated() {
            for i in 0...count {
                let r = ring[i % count]
                _ = vertex(frame.point([r.p.x, y, r.p.y]), frame.normal([r.n.x, 0, r.n.y]),
                           side.map(perim[i] / total, Float(yi)))
            }
        }
        let row = UInt32(count + 1)
        for i in 0..<UInt32(count) {
            let a = base + i, b = a + 1, c = a + row, d = c + 1
            tri(a, c, d); tri(a, d, b)
        }
        // Denka: wachlarz od środka.
        for (y, ny) in [(y0, Float(-1)), (y1, Float(1))] {
            let center = vertex(frame.point([0, y, 0]), frame.normal([0, ny, 0]), cap.map(0.5, 0.5))
            let first = UInt32(positions.count)
            for r in ring {
                _ = vertex(frame.point([r.p.x, y, r.p.y]), frame.normal([0, ny, 0]),
                           cap.map(r.p.x / (2 * halfX) + 0.5, r.p.y / (2 * halfZ) + 0.5))
            }
            for i in 0..<UInt32(count) { tri(center, first + i, first + (i + 1) % UInt32(count)) }
        }
    }

    /// Tablica: cienka płyta z zaokrąglonymi narożnikami w płaszczyźnie XY układu (środek w początku),
    /// przód (+Z) z obrazem `front`, tył i krawędzie z `back`.
    mutating func board(width: Float, height: Float, thickness: Float, corner: Float, frame: Frame,
                        front: PropAtlas.Rect, back: PropAtlas.Rect) {
        // Graniastosłup wzdłuż Y obrócony tak, że Y → Z (grubość), a przekrój XZ → XY.
        let f = frame.child(origin: [0, 0, -thickness / 2], x: [1, 0, 0], y: [0, 0, 1], z: [0, -1, 0])
        // Przekrój: X — szerokość, Z (po obrocie −Y) — wysokość; denko górne (y1) to przód tablicy.
        prism(halfX: width / 2, halfZ: height / 2, corner: corner, y0: 0, y1: thickness, frame: f,
              side: .rect(back), cap: .rect(back))
        // Przód: denko y1 — jego wierzchołki (ostatnie count + 1) dostają UV obrazu.
        let capCount = 4 * 5 + 1
        let frontStart = positions.count - capCount
        for i in frontStart..<positions.count {
            let p = positions[i] - frame.origin
            let lx = simd_dot(p, simd_normalize(frame.x)), ly = simd_dot(p, simd_normalize(frame.y))
            uvs[i] = front.map(lx / width + 0.5, ly / height + 0.5)
        }
    }

    /// Tkanina banera w płaszczyźnie XY układu, lekko pofalowana; dwie strony z tym samym wzorem.
    mutating func cloth(x0: Float, x1: Float, y0: Float, y1: Float, frame: Frame, design: PropAtlas.Rect) {
        let nx = 6, ny = 10
        for sideSign in [Float(1), -1] {
            let base = UInt32(positions.count)
            for j in 0...ny {
                for i in 0...nx {
                    let u = Float(i) / Float(nx), v = Float(j) / Float(ny)
                    // Fala: tkanina wybrzusza się między wysięgnikami.
                    let wave = 0.035 * sin(u * .pi) * sin(v * .pi * 1.5 + 0.4)
                    let dw = 0.035 * .pi * cos(u * .pi) * sin(v * .pi * 1.5 + 0.4) / (x1 - x0)
                    let z = wave + sideSign * 0.002
                    let p = SIMD3<Float>(x0 + (x1 - x0) * u, y0 + (y1 - y0) * v, z)
                    let n = simd_normalize(SIMD3<Float>(-dw, 0, 1)) * sideSign
                    _ = vertex(frame.point(p), frame.normal(n), design.map(sideSign > 0 ? u : 1 - u, v))
                }
            }
            let row = UInt32(nx + 1)
            for j in 0..<UInt32(ny) {
                for i in 0..<UInt32(nx) {
                    let a = base + j * row + i, b = a + 1, c = a + row, d = c + 1
                    tri(a, b, d); tri(a, d, c)
                }
            }
        }
    }

    /// Taśma bariery W wzdłuż trasy po stronie `side`, od s0 do s1: lico od jezdni w odległości `front`
    /// od osi, wysokość 0,31 m od `y0`. Profil: dwie fale w stronę jezdni (głębokość 8,5 cm).
    mutating func wBeam(_ track: Track, side: Double, s0: Double, s1: Double, front: Double, y0: Float) {
        let steps = 14, height: Float = 0.31, depth: Float = 0.085
        func profile(_ k: Int) -> (q: Float, y: Float, dq: Float) {
            let t = Float(k) / Float(steps)
            let h = t * height
            // x(h): 0 przy brzegach i w środku, głębokość w falach; q — odległość od lica w głąb.
            let x = depth / 2 * (1 - cos(4 * .pi * t))
            let dx = depth / 2 * 4 * .pi / height * sin(4 * .pi * t)
            return (depth - x, y0 + h, -dx)
        }
        var samples = Array(stride(from: s0, to: s1, by: track.ds))
        samples.append(s1)
        for back in [false, true] {
            let base = UInt32(positions.count)
            for s in samples {
                let w = track.toWorld(s: s, d: 0)
                let left = SIMD3<Float>(Float(cos(w.heading)), 0, Float(-sin(w.heading)))
                let outward = side > 0 ? left : -left
                for k in 0...steps {
                    let pr = profile(k)
                    let q = Double(pr.q) + (back ? 0.004 : 0)
                    let p = track.toWorld(s: s, d: side * (front + q))
                    // Normalna lica: ku jezdni (−outward), pochylona zgodnie ze spadkiem profilu.
                    var n = simd_normalize(-outward + SIMD3<Float>(0, 1, 0) * pr.dq)
                    if back { n = -n }
                    _ = vertex([Float(p.x), pr.y, Float(p.z)], n, [Float(s / 4), Float(k) / Float(steps) * 0.3])
                }
            }
            let row = UInt32(steps + 1)
            for i in 0..<UInt32(max(0, samples.count - 1)) {
                for k in 0..<UInt32(steps) {
                    let a = base + i * row + k, b = a + 1, c = a + row, d = c + 1
                    tri(a, c, d); tri(a, d, b)
                }
            }
        }
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
