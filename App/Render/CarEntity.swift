import CoreGraphics
import Foundation
import RaceCore
import RealityKit
import UIKit

/// Auto: gotowy model OBJ (App/Models/Cars), a gdy go brak — opływowe nadwozie generowane z przekrojów.
/// Przód patrzy w +Z.
@MainActor
final class CarEntity {
    /// Pozycja i kierunek auta.
    let root = Entity()
    /// Całe auto razem z kołami — koziołkuje przy rozbiciu (`setWreck`).
    private let frame = Entity()
    /// Nadwozie na zawieszeniu — przechyla się nad kołami, które zostają na jezdni.
    let body = Entity()
    private var paintParts: [ModelEntity] = []
    private var flames: [ModelEntity] = []
    private var wheels: [Entity] = []
    private var smoke: [Entity] = []
    private var smoking = false
    private var flameMode: NitroMode = .off
    private var wheelRadius: Float = 0.36
    /// Paleta modelu i pole lakieru — lakier przemalowuje się, podmieniając to pole.
    private var basePalette: CGImage?
    private var paintRef: CarModelRef?

    init(def: CarDef, color: UIColor) {
        let s = def.shape
        let L = Float(s.length), W = Float(s.width)
        let hScale = Float(s.height) / 1.2
        root.addChild(frame)
        frame.addChild(body)
        if let r = def.realistic, let template = LocalAssets.shared.templates[r.file] {
            let d = buildRealistic(template: template, ref: r, color: color)
            addEffects(width: d.width, rearZ: d.rearZ, exhaustY: d.exhaustY, backWheelX: d.backWheelX, backWheelZ: d.backWheelZ)
            return
        }
        if let ref = def.model, let d = buildModel(ref: ref, def: def, color: color) {
            addEffects(width: d.width, rearZ: d.rearZ, exhaustY: d.exhaustY, backWheelX: d.backWheelX, backWheelZ: d.backWheelZ)
            spinWheels(distance: 0)
            return
        }
        let paint = Materials.paint(color)

        func add(_ mesh: MeshResource?, _ material: any Material, painted: Bool = false) {
            guard let mesh else { return }
            let e = ModelEntity(mesh: mesh, materials: [material])
            body.addChild(e)
            if painted { paintParts.append(e) }
        }

        // Nadwozie: przekroje od tyłu (t = 0) do przodu (t = 1).
        let wheelT: [Float] = [0.18, 0.82]
        func bump(_ t: Float) -> Float { wheelT.map { exp(-pow(($0 - t) / 0.07, 2)) }.max()! }
        func bodyTop(_ t: Float) -> Float {
            let base = curve(t, [(0, 0.52), (0.05, 0.70), (0.3, 0.74), (0.62, 0.70), (0.9, 0.58), (1, 0.44)])
            return (base + 0.05 * bump(t)) * hScale
        }
        func bodyBottom(_ t: Float) -> Float { curve(t, [(0, 0.3), (0.05, 0.22), (0.95, 0.22), (1, 0.26)]) }
        func halfWidth(_ t: Float) -> Float {
            (curve(t, [(0, 0.88), (0.05, 0.96), (0.2, 0.98), (0.8, 0.98), (0.95, 0.92), (1, 0.8)]) + 0.05 * bump(t)) * W / 2
        }
        var bodyRings: [[SIMD3<Float>]] = []
        let n = 40
        for i in 0...n {
            let t = Float(i) / Float(n)
            bodyRings.append(Self.ring(z: -L / 2 + t * L, halfWidth: halfWidth(t), bottom: bodyBottom(t), top: bodyTop(t),
                                       exponent: 4.5, topTaper: 0.08))
        }
        // Zaokrąglone końce: dwa coraz mniejsze przekroje za zderzakami.
        for (end, dir) in [(0, Float(-1)), (n, Float(1))] {
            let r = bodyRings[end]
            let c = r.reduce(SIMD3<Float>(repeating: 0), +) / Float(r.count)
            let extra = [0.94, 0.75].enumerated().map { k, sc in
                r.map { p in c + (p - c) * Float(sc) + SIMD3<Float>(0, 0, dir * Float(k + 1) * 0.03) }
            }
            if end == 0 { bodyRings.insert(contentsOf: extra.reversed(), at: 0) } else { bodyRings += extra }
        }
        var lb = LoftBuilder()
        lb.loft(bodyRings, closed: true, capEnds: true)
        add(try? lb.mesh(name: "body"), paint, painted: true)

        // Kabina: szkło, z pochyloną przednią i tylną szybą.
        let tc = 0.5 + Float(s.cabinOffset) / L
        let cl = Float(s.cabinLength)
        let c0 = tc - cl / 2 - 0.1, c1 = tc + cl / 2 + 0.14
        let roofH: Float = 0.46 * hScale
        func cabinTop(_ t: Float) -> Float {
            let u = (t - c0) / (c1 - c0)
            let rise = smoothstep(0, 0.32, u) * (1 - smoothstep(0.62, 1, u))
            return bodyTop(t) - 0.04 + roofH * rise
        }
        var cabinRings: [[SIMD3<Float>]] = []
        let m = 28
        for i in 0...m {
            let t = c0 + (c1 - c0) * Float(i) / Float(m)
            cabinRings.append(Self.ring(z: -L / 2 + t * L, halfWidth: halfWidth(t) * 0.84, bottom: bodyTop(t) - 0.12,
                                        top: max(bodyTop(t) - 0.08, cabinTop(t)), exponent: 3, topTaper: 0.3))
        }
        var cb = LoftBuilder()
        cb.loft(cabinRings, closed: true, capEnds: false)
        add(try? cb.mesh(name: "cabin"), Materials.glass)

        // Dach w kolorze lakieru: górny pas kabiny w jej płaskiej części, minimalnie nad szybą.
        var roofRings: [[SIMD3<Float>]] = []
        let r0 = c0 + (c1 - c0) * 0.36, r1 = c0 + (c1 - c0) * 0.6
        for i in 0...10 {
            let t = r0 + (r1 - r0) * Float(i) / 10
            roofRings.append(Self.ring(z: -L / 2 + t * L, halfWidth: halfWidth(t) * 0.84 * 1.015, bottom: bodyTop(t) - 0.12,
                                       top: cabinTop(t) + 0.012, exponent: 3, topTaper: 0.3, arc: 0.3...2.84))
        }
        var rb = LoftBuilder()
        rb.loft(roofRings, closed: false, capEnds: false)
        add(try? rb.mesh(name: "roof"), paint, painted: true)

        // Światła: przednie reflektory i pas świateł tylnych.
        let headY = bodyTop(0.97) - 0.08
        for side: Float in [-1, 1] {
            let h = ModelEntity(mesh: .generateBox(width: W * 0.24, height: 0.08, depth: 0.12, cornerRadius: 0.04),
                                materials: [Materials.glow(UIColor(red: 0.85, green: 0.93, blue: 1, alpha: 1), intensity: 3)])
            h.position = [side * W * 0.3, headY, L / 2 + 0.01]
            body.addChild(h)
            // Lusterka.
            let mirror = ModelEntity(mesh: .generateBox(width: 0.18, height: 0.1, depth: 0.12, cornerRadius: 0.04), materials: [paint])
            mirror.position = [side * (halfWidth(c1 - 0.06) * 0.86 + 0.06), bodyTop(c1 - 0.06) + 0.08, -L / 2 + (c1 - 0.06) * L]
            body.addChild(mirror)
            paintParts.append(mirror)
        }
        let tail = ModelEntity(mesh: .generateBox(width: W * 0.64, height: 0.07, depth: 0.08, cornerRadius: 0.03),
                               materials: [Materials.glow(UIColor(red: 1, green: 0.08, blue: 0.1, alpha: 1), intensity: 2.5)])
        tail.position = [0, bodyTop(0.02) - 0.09, -L / 2 - 0.03]
        body.addChild(tail)

        if s.spoiler {
            let wing = ModelEntity(mesh: .generateBox(width: W * 0.95, height: 0.06, depth: 0.36, cornerRadius: 0.03), materials: [paint])
            wing.position = [0, bodyTop(0.06) + 0.3, -L / 2 + 0.3]
            body.addChild(wing)
            paintParts.append(wing)
            for side: Float in [-1, 1] {
                let stand = ModelEntity(mesh: .generateBox(width: 0.05, height: 0.3, depth: 0.12, cornerRadius: 0.02),
                                        materials: [Materials.matte(UIColor(white: 0.1, alpha: 1), roughness: 0.4, metallic: 0.6)])
                stand.position = [side * W * 0.3, bodyTop(0.06) + 0.15, -L / 2 + 0.3]
                body.addChild(stand)
            }
        }

        // Koła: opona, felga i szprychy. Oś koła wzdłuż X.
        let tire = MeshResource.generateCylinder(height: 0.26, radius: wheelRadius)
        let rim = MeshResource.generateCylinder(height: 0.27, radius: 0.24)
        let spoke = MeshResource.generateBox(width: 0.03, height: 0.4, depth: 0.05)
        let rubber = Materials.matte(UIColor(white: 0.05, alpha: 1), roughness: 0.9)
        let spokeMat = Materials.matte(UIColor(white: 0.25, alpha: 1), roughness: 0.3, metallic: 1)
        for sx: Float in [-1, 1] {
            for (k, t) in wheelT.enumerated() {
                let wheel = Entity()
                wheel.position = [sx * (halfWidth(t) - 0.12), wheelRadius, -L / 2 + t * L + (k == 0 ? 0.05 : -0.05)]
                let lay = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
                let t1 = ModelEntity(mesh: tire, materials: [rubber]); t1.orientation = lay
                let r1 = ModelEntity(mesh: rim, materials: [Materials.chrome]); r1.orientation = lay
                wheel.addChild(t1)
                wheel.addChild(r1)
                for i in 0..<5 {
                    let sp = ModelEntity(mesh: spoke, materials: [spokeMat])
                    sp.position = [sx * 0.14, 0, 0]
                    sp.orientation = simd_quatf(angle: Float(i) * 2 * .pi / 5, axis: [1, 0, 0])
                    wheel.addChild(sp)
                }
                frame.addChild(wheel)
                wheels.append(wheel)
            }
        }

        addEffects(width: W, rearZ: -L / 2 - 0.1, exhaustY: 0.38, backWheelX: halfWidth(0.18) - 0.1, backWheelZ: -L / 2 + 0.18 * L)
        spinWheels(distance: 0)
    }

    private struct ModelDims {
        var width: Float
        var rearZ: Float
        var exhaustY: Float
        var backWheelX: Float
        var backWheelZ: Float
    }

    /// Buduje auto z modelu OBJ, skalując je do długości z `CarDef`. Koła stają się osobnymi encjami
    /// obracanymi wokół własnego środka; części z paletą dostają przemalowany lakier.
    private func buildModel(ref: CarModelRef, def: CarDef, color: UIColor) -> ModelDims? {
        let lib = ModelLibrary.shared
        guard let l = lib.load("Cars/" + ref.file) else { return nil }
        let b = l.model.bounds
        let s = Float(def.shape.length) / (b.max.z - b.min.z)
        if let tex = l.materials.values.compactMap(\.texture).first {
            basePalette = lib.image(l.folder.appendingPathComponent(tex))
        }
        paintRef = ref
        let paint = modelPaint(color)
        let holder = Entity()
        holder.scale = [s, s, s]
        body.addChild(holder)

        var backWheel = SIMD3<Float>((b.max.x - b.min.x) * 0.38, 0.3, b.min.z * 0.6)
        for g in l.model.groups {
            if g.name.hasPrefix("wheel") {
                let pts = g.parts.flatMap(\.positions)
                guard !pts.isEmpty else { continue }
                let lo = pts.reduce(SIMD3<Float>(repeating: .infinity)) { pointwiseMin($0, $1) }
                let hi = pts.reduce(SIMD3<Float>(repeating: -.infinity)) { pointwiseMax($0, $1) }
                let center = (lo + hi) / 2
                let pivot = Entity()
                pivot.position = center * s
                pivot.scale = [s, s, s]
                for p in g.parts {
                    guard let mesh = lib.mesh(p, offset: center) else { continue }
                    pivot.addChild(ModelEntity(mesh: mesh, materials: [lib.material(l.materials[p.material] ?? ObjMaterial(), folder: l.folder)]))
                }
                frame.addChild(pivot)
                wheels.append(pivot)
                wheelRadius = (hi.y - lo.y) / 2 * s
                if g.name == "wheel-back-left" { backWheel = center }
            } else {
                for p in g.parts {
                    guard let mesh = lib.mesh(p) else { continue }
                    let usesPalette = l.materials[p.material]?.texture != nil
                    let e = ModelEntity(mesh: mesh, materials: [usesPalette ? paint : lib.material(l.materials[p.material] ?? ObjMaterial(), folder: l.folder)])
                    holder.addChild(e)
                    if usesPalette { paintParts.append(e) }
                }
            }
        }
        return ModelDims(width: (b.max.x - b.min.x) * s, rearZ: b.min.z * s, exhaustY: 0.25 * s,
                         backWheelX: abs(backWheel.x) * s, backWheelZ: backWheel.z * s)
    }

    /// Realistyczny model USDZ (już znormalizowany i scalony): klon współdzielący siatki i tekstury wzorca.
    /// Lakier to siatki o nazwach z `paintParts` (dokładne nazwy prim USD przypiętych do materiału lakieru),
    /// a we wzorcu scalonym — siatki `merged_paint_*` (`CarMeshMerge`).
    private func buildRealistic(template: Entity, ref: RealisticModelRef, color: UIColor) -> ModelDims {
        let car = template.clone(recursive: true)
        body.addChild(car)
        let names = Set(ref.paintParts)
        func walk(_ e: Entity, inPaint: Bool) {
            let hit = inPaint || names.contains(e.name) || e.name.hasPrefix(CarMeshMerge.paintPrefix)
            if hit, let m = e as? ModelEntity { paintParts.append(m) }
            for c in e.children { walk(c, inPaint: hit) }
        }
        walk(car, inPaint: false)
        realisticPaint = true
        for p in paintParts { Self.repaint(p, color) }
        rigRealisticWheels(car, file: ref.file)
        let b = car.visualBounds(relativeTo: root)
        return ModelDims(width: b.extents.x, rearZ: b.min.z, exhaustY: 0.4,
                         backWheelX: b.extents.x * 0.4, backWheelZ: b.min.z * 0.62)
    }

    private var realisticPaint = false

    /// Przemalowanie części realistycznego modelu: kolor lakieru z połyskiem, bez oryginalnej tekstury koloru.
    private static func repaint(_ e: ModelEntity, _ color: UIColor) {
        guard var model = e.model else { return }
        model.materials = model.materials.map { m in
            guard var p = m as? PhysicallyBasedMaterial else { return Materials.paint(color) }
            Materials.applyPaint(&p, color)
            return p
        }
        e.model = model
    }

    /// Lakier modelu: paleta z przemalowanym polem, z połyskiem bezbarwnego lakieru.
    private func modelPaint(_ color: UIColor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.roughness = 0.35
        m.metallic = 0.2
        m.clearcoat = 1.0
        m.clearcoatRoughness = 0.05
        let lib = ModelLibrary.shared
        if let base = basePalette, let ref = paintRef,
           let tex = lib.paletteTexture(lib.paintedPalette(base, row: ref.paintRow, column: ref.paintColumn, color: color)) {
            m.baseColor = .init(tint: .white, texture: .init(tex, sampler: ModelLibrary.paletteSampler))
        }
        return m
    }

    // MARK: - Cień kontaktowy

    /// Cień kontaktowy, jak w grach wyścigowych (zapieczone „ambient occlusion” pod autem): miękka ciemna
    /// plama pod podwoziem i mocniej przyciemnione miejsca styku opon z asfaltem. Bez tego cień słońca
    /// (mapa cieni o ograniczonej rozdzielczości) nie dochodzi do samych opon i auto wygląda, jakby
    /// tonęło albo wisiało. Leży na jezdni (w `root`), nie przechyla się z nadwoziem.
    func addContactShadow() {
        guard let materials = Self.contactMaterials else { return }
        let b = body.visualBounds(relativeTo: root)
        let under = ModelEntity(mesh: .generatePlane(width: b.extents.x + 0.35, depth: b.extents.z + 0.5),
                                materials: [materials.body])
        under.position = [b.center.x, Self.shadowLift, b.center.z]
        root.addChild(under)
        let patch = MeshResource.generatePlane(width: 0.55, depth: max(0.6, wheelRadius * 1.9))
        for w in wheels {
            let e = ModelEntity(mesh: patch, materials: [materials.tyre])
            e.position = [w.position.x, Self.shadowLift + 0.0005, w.position.z]
            root.addChild(e)
            contactShadows.append(e)
        }
        contactShadows.append(under)
    }

    private var contactShadows: [Entity] = []
    private var sparkEmitters: [Entity] = []

    /// Snop iskier z boku auta (`side` +1 — lewy, −1 — prawy, jak `d` na trasie); `intensity` — prędkość
    /// wbicia w bandę (m/s), od niej zależy liczba iskier.
    func sparks(side: Double, intensity: Double) {
        guard sparkEmitters.count == 2 else { return }
        let e = sparkEmitters[side > 0 ? 1 : 0]
        guard var emitter = e.components[ParticleEmitterComponent.self] else { return }
        emitter.burstCount = Int(min(160, 30 + intensity * 8))
        emitter.burst()
        e.components.set(emitter)
    }

    private static func sparkEmitter(side: Float) -> ParticleEmitterComponent {
        var p = ParticleEmitterComponent()
        p.mainEmitter.image = ParticleTextures.dot
        p.emitterShape = .point
        p.isEmitting = false
        p.speed = 7
        p.speedVariation = 4
        p.emissionDirection = [side, 0.6, -0.4]
        p.birthDirection = .local
        p.mainEmitter.birthRate = 0
        p.mainEmitter.lifeSpan = 0.35
        p.mainEmitter.lifeSpanVariation = 0.2
        p.mainEmitter.spreadingAngle = 0.7
        p.mainEmitter.size = 0.035
        p.mainEmitter.sizeVariation = 0.015
        p.mainEmitter.stretchFactor = 6
        p.mainEmitter.acceleration = [0, -9.8, 0]
        p.mainEmitter.dampingFactor = 1.5
        p.mainEmitter.blendMode = .additive
        p.mainEmitter.color = .evolving(start: .single(UIColor(red: 1, green: 0.95, blue: 0.7, alpha: 1)),
                                        end: .single(UIColor(red: 1, green: 0.35, blue: 0.05, alpha: 0)))
        p.burstCountVariation = 10
        return p
    }
    /// Nad asfaltem i liniami, pod śladami opon (względem wierzchu jezdni 0,02: 0,032).
    private static let shadowLift: Float = 0.012

    private static let contactMaterials: (body: UnlitMaterial, tyre: UnlitMaterial)? = {
        func material(_ image: CGImage?, _ opacity: Float) -> UnlitMaterial? {
            guard let image, let tex = try? TextureResource(image: image, options: .init(semantic: .raw, mipmapsMode: .allocateAndGenerateAll))
            else { return nil }
            var m = UnlitMaterial(color: .black)
            m.blending = .transparent(opacity: .init(scale: opacity, texture: .init(tex)))
            return m
        }
        guard let body = material(softBox(), 0.62), let tyre = material(softBlob(), 0.8) else { return nil }
        return (body, tyre)
    }()

    /// Zaokrąglony prostokąt z bardzo miękkim brzegiem (ciemno pod podwoziem, zero na zewnątrz).
    private static func softBox() -> CGImage? {
        let w = 64, h = 128
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                // Odległość od brzegu w ułamku połowy wymiaru (0 na brzegu, 1 w środku).
                let ex = 1 - abs(Float(x) + 0.5 - Float(w) / 2) / (Float(w) / 2)
                let ey = 1 - abs(Float(y) + 0.5 - Float(h) / 2) / (Float(h) / 2)
                let v = smoothstep(0, 0.45, ex) * smoothstep(0, 0.3, ey)
                px[y * w + x] = UInt8(min(255, v * 255))
            }
        }
        ctx.data?.copyMemory(from: px, byteCount: px.count)
        return ctx.makeImage()
    }

    /// Eliptyczna plamka pod oponą: najciemniej w miejscu styku.
    private static func softBlob() -> CGImage? {
        let n = 64
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        var px = [UInt8](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let dx = (Float(x) + 0.5) / Float(n) * 2 - 1, dy = (Float(y) + 0.5) / Float(n) * 2 - 1
                let r = sqrt(dx * dx + dy * dy)
                let v = 1 - smoothstep(0.15, 1, r)
                px[y * n + x] = UInt8(min(255, v * v * 255))
            }
        }
        ctx.data?.copyMemory(from: px, byteCount: px.count)
        return ctx.makeImage()
    }

    private func addEffects(width W: Float, rearZ: Float, exhaustY: Float, backWheelX: Float, backWheelZ: Float) {
        // Płomień nitro: miękki jęzor ognia (skrzyżowane płaty + poświata dyszy) tuż za wydechem.
        for side: Float in [-1, 1] {
            let exhaust = Entity()
            exhaust.position = [side * W * 0.2, exhaustY, rearZ - 0.15]
            let core = ModelEntity(mesh: Self.flameMesh, materials: [Self.flame(.normal)])
            core.position.z = 0
            exhaust.addChild(core)
            core.isEnabled = false
            body.addChild(exhaust)
            flames.append(core)
        }
        // Iskry przy uderzeniu w bandę: po jednym emiterze na bok, przy przednim narożniku.
        for sx: Float in [-1, 1] {
            let e = Entity()
            e.position = [sx * W * 0.5, 0.25, -rearZ * 0.55]
            e.components.set(Self.sparkEmitter(side: sx))
            root.addChild(e)
            sparkEmitters.append(e)
        }
        for sx: Float in [-1, 1] {
            let e = Entity()
            // Nad jezdnią: duże cząsteczki rodzące się nisko były ucinane przez asfalt prostą krawędzią.
            e.position = [sx * backWheelX, 0.45, backWheelZ - 0.5]
            root.addChild(e)
            smoke.append(e)
        }
    }

    /// Przekrój nadwozia: zaokrąglony prostokąt (superelipsa), zwężany ku górze o `topTaper`.
    private static func ring(z: Float, halfWidth: Float, bottom: Float, top: Float, exponent: Float, topTaper: Float,
                             arc: ClosedRange<Float>? = nil, count: Int = 32) -> [SIMD3<Float>] {
        let cy = (top + bottom) / 2, hh = max(0.01, (top - bottom) / 2)
        let e = 2 / exponent
        return (0..<count).map { i in
            let a: Float = arc.map { $0.lowerBound + ($0.upperBound - $0.lowerBound) * Float(i) / Float(count - 1) }
                ?? Float(i) / Float(count) * 2 * .pi
            let c = cos(a), s = sin(a)
            let y = cy + hh * copysign(pow(abs(s), e), s)
            let k = 1 - topTaper * max(0, (y - bottom) / (top - bottom))
            return [halfWidth * k * copysign(pow(abs(c), e), c), y, z]
        }
    }

    /// Kolor płomienia: niebieski (nitro), fioletowy (perfect), pomarańczowy (fala).
    private static func flameColor(_ mode: NitroMode) -> UIColor {
        switch mode {
        case .off, .normal: UIColor(red: 0.25, green: 0.65, blue: 1, alpha: 1)
        case .perfect: UIColor(red: 0.8, green: 0.25, blue: 1, alpha: 1)
        case .shockwave: UIColor(red: 1, green: 0.55, blue: 0.1, alpha: 1)
        }
    }

    /// Rdzeń płomienia: tekstura „jęzora” w kolorze trybu, przezroczystość zanika wzdłuż i ku brzegom.
    private static var flameMaterials: [NitroMode: UnlitMaterial] = [:]

    private static func flame(_ mode: NitroMode) -> UnlitMaterial {
        if let m = flameMaterials[mode] { return m }
        let m = makeFlame(mode)
        flameMaterials[mode] = m
        return m
    }


    /// Długość jęzora i promień poświaty dyszy (m) przy skali 1.
    private static let flameLength: Float = 1.4
    private static let flameWidth: Float = 0.3

    /// Siatka płomienia (wzdłuż −Z od dyszy w zerze): trzy skrzyżowane płaty z teksturą
    /// jęzora — z boku i z góry widać smugę — oraz płat poprzeczny z samą „głową” tekstury: z tyłu, skąd
    /// patrzy kamera, płomień to miękka okrągła poświata, a nie cienka kreska ani kula. Bez oświetlenia,
    /// dwustronny. Tekstura: v = 0…0,25 to okrągła głowa (tylko płat poprzeczny), dalej ogon (płaty wzdłuż).
    private static let flameMesh: MeshResource = {
        var b = MeshBuilder()
        let L = flameLength, w = flameWidth / 2
        // Płaty od dyszy do końca jęzora, z samym ogonem tekstury (v od 0,25): z tyłu, prawie na krawędź,
        // jasna głowa na płatach rysowała się jako gwiazdka. Głowę daje tylko płat poprzeczny.
        let z1 = -L, z0: Float = 0
        let uv: [SIMD2<Float>] = [[0, 0.25], [1, 0.25], [1, 1], [0, 1]]
        // Trzy płaty co 60° wokół osi płomienia — z żadnej strony nie widać go „na krawędź”.
        for k in 0..<3 {
            let a = Float(k) * .pi / 3
            let x = SIMD3<Float>(cos(a), sin(a), 0) * w
            b.quad(SIMD3(-x.x, -x.y, z0), SIMD3(x.x, x.y, z0), SIMD3(x.x, x.y, z1), SIMD3(-x.x, -x.y, z1), uv: uv, doubleSided: true)
        }
        // Poprzeczny płat: głowa tekstury (v 0…0,25), kwadrat ok. 1,4 × szerokość płomienia.
        let r = w * 1.0
        let head: [SIMD2<Float>] = [[0, 0], [1, 0], [1, 0.25], [0, 0.25]]
        b.quad([-r, -r, -0.02], [r, -r, -0.02], [r, r, -0.02], [-r, r, -0.02], uv: head, doubleSided: true)
        return (try? b.mesh(name: "flame")) ?? .generateSphere(radius: 0.05)
    }()

    /// Tekstura jęzora (64 × 256, v wzdłuż): biało-niebieski żar przy dyszy, dalej kolor trybu przechodzący
    /// w pomarańcz i zanikający ku końcowi; w poprzek miękki brzeg (gauss). `alpha` — osobna tekstura krycia (szarość).
    private static func flameImages(_ mode: NitroMode) -> (color: CGImage, alpha: CGImage)? {
        let w = 64, h = 256
        let c = flameColor(mode)
        var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
        c.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        var alpha = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            // Wiersz 0 obrazu to góra, a v = 0 w UV RealityKit to dół obrazu — liczymy v od dołu.
            let v = 1 - (Float(y) + 0.5) / Float(h)
            for x in 0..<w {
                let u = (Float(x) + 0.5) / Float(w) * 2 - 1
                var a: Float
                var hot: Float
                if v < 0.25 {
                    // Głowa: okrągła, miękka plama (64 × 64 px) — z niej też poświata dyszy.
                    let dy = (v - 0.125) / 0.125
                    let r = sqrt(u * u + dy * dy)
                    // Przygaszona i mniejsza niż ogon — przy dyszy ma być żar, a nie świecąca kula.
                    a = 0.75 * max(0, 1 - smoothstep(0.05, 0.85, r))
                    hot = 0.8 * max(0, 1 - smoothstep(0, 0.4, r))
                } else {
                    // Ogon: zwęża się i zanika ku końcowi, z lekkim „szarpaniem” krawędzi.
                    let t = (v - 0.25) / 0.75
                    let width = 0.5 * (1 - 0.7 * t)
                    let ripple = 1 + 0.12 * sin(t * 26 + u * 3)
                    // Na początku ogon narasta od zera — płaty nie mają ostrej krawędzi przy dyszy.
                    a = exp(-pow(u / (width * ripple), 2) * 2.2) * pow(1 - t, 1.9) * smoothstep(0, 0.14, t)
                    // Niebieski rdzeń ciągnie się przez pierwszą połowę jęzora.
                    hot = exp(-pow(u / (width * 0.45), 2) * 2) * max(0, 1 - t * 1.6)
                }
                a = min(1, max(0, a))
                hot = min(1, max(0, hot))
                // Kolor: biało-niebieski żar przy dyszy → kolor trybu → pomarańcz dopalania na końcu jęzora.
                let warm = smoothstep(0.35, 0.75, v)
                let fade: Float = v < 0.25 ? 1 : 1 - 0.3 * (v - 0.25) / 0.75
                let mr = (Float(cr) * (1 - warm) + 1.0 * warm) * fade
                let mg = (Float(cg) * (1 - warm) + 0.5 * warm) * fade
                let mb = (Float(cb) * (1 - warm) + 0.06 * warm) * fade
                let r = mr * (1 - hot) + (0.75 + 0.25 * Float(cr)) * hot
                let g = mg * (1 - hot) + (0.82 + 0.18 * Float(cg)) * hot
                let bl = mb * (1 - hot) + (0.9 + 0.1 * Float(cb)) * hot
                let i = (y * w + x)
                rgba[i * 4] = UInt8(min(255, r * 255))
                rgba[i * 4 + 1] = UInt8(min(255, g * 255))
                rgba[i * 4 + 2] = UInt8(min(255, bl * 255))
                rgba[i * 4 + 3] = 255
                alpha[i] = UInt8(min(255, a * 255))
            }
        }
        guard let cctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let actx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        cctx.data?.copyMemory(from: rgba, byteCount: rgba.count)
        actx.data?.copyMemory(from: alpha, byteCount: alpha.count)
        guard let ci = cctx.makeImage(), let ai = actx.makeImage() else { return nil }
        return (ci, ai)
    }

    private static func makeFlame(_ mode: NitroMode) -> UnlitMaterial {
        let c = flameColor(mode)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        let fallback = UIColor(red: 0.35 + r * 0.65, green: 0.35 + g * 0.65, blue: 0.35 + b * 0.65, alpha: 1)
        guard let img = flameImages(mode),
              let ct = try? TextureResource(image: img.color, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll)),
              let at = try? TextureResource(image: img.alpha, options: .init(semantic: .raw, mipmapsMode: .allocateAndGenerateAll))
        else {
            var m = UnlitMaterial(color: fallback)
            m.blending = .transparent(opacity: .init(floatLiteral: 0.75))
            return m
        }
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(ct))
        m.blending = .transparent(opacity: .init(scale: 0.95, texture: .init(at)))
        m.faceCulling = .none
        return m
    }

    func setColor(_ color: UIColor) {
        if realisticPaint {
            for p in paintParts { Self.repaint(p, color) }
        } else if paintRef != nil {
            let m = modelPaint(color)
            for p in paintParts { p.model?.materials = [m] }
        } else {
            let m = Materials.paint(color)
            for p in paintParts { p.model?.materials = [m] }
        }
    }

    #if DEBUG || FAMILY
    /// `-previewFX`: płomień nitro stale włączony, a obok auta stoją butle nitro — do zrzutów efektów
    /// z bliska (z `-sideCam`).
    static let previewFX = ProcessInfo.processInfo.arguments.contains("-previewFX")
    private var previewAdded = false
    #endif

    func setFlame(_ mode: NitroMode) {
        var mode = mode
        #if DEBUG || FAMILY
        if Self.previewFX {
            if mode == .off { mode = .normal }
            if !previewAdded {
                previewAdded = true
                for (x, z) in [(Float(-1.9), Float(1.6)), (Float(1.9), Float(1.6))] {
                    let c = NitroCanister.make()
                    c.position = [x, 0.9, z]
                    root.addChild(c)
                }
            }
        }
        #endif
        if mode != flameMode {
            // Materiały płomienia są zbuforowane per tryb — przy zmianie tylko je podmieniamy.
            // Bez strumienia cząsteczek: przy dużej prędkości cząsteczki zostawały metr za jęzorem
            // jako oderwane fioletowe kłęby; miękki jęzor sam daje płomień.
            let colourChanged = mode != .off && flameColorKey(mode) != flameColorKey(lastFlameColor)
            debugLog("efekt: nitro \(mode)")
            flameMode = mode
            if mode != .off {
                lastFlameColor = mode
                for f in flames {
                    if colourChanged { f.model?.materials = [Self.flame(mode)] }
                    f.isEnabled = true
                }
            } else {
                for f in flames { f.isEnabled = false }
            }
        }
        guard mode != .off else { return }
        // Migotanie jęzora: płomień „oddycha” — grubość i długość drgają niezależnie, a płaty lekko
        // obracają się wokół osi, więc kształt nie wygląda na sztywną geometrię.
        let base: Float = mode == .shockwave ? 1.4 : mode == .perfect ? 1.2 : 1
        for f in flames {
            let k = Float.random(in: 0.85...1.15)
            f.scale = [base * k, base * k, base * Float.random(in: 0.8...1.2)]
            f.orientation = simd_quatf(angle: Float.random(in: 0...(.pi / 3)), axis: [0, 0, 1])
        }
    }

    private var lastFlameColor: NitroMode = .normal
    private func flameColorKey(_ m: NitroMode) -> NitroMode { m == .off ? .normal : m }

    /// Dalej niż tyle metrów od kamery dym nie jest emitowany — 12 emiterów po 110 cząsteczek/s to
    /// zauważalny koszt, a z daleka smugi i tak prawie nie widać.
    static let smokeRange: Float = 60

    #if DEBUG || FAMILY
    /// `-noSmoke`: drift bez dymu (pomiar kosztu A/B).
    private static let smokeOff = ProcessInfo.processInfo.arguments.contains("-noSmoke")
    #else
    private static let smokeOff = false
    #endif

    /// Dym spod tylnych kół. `viewer` — pozycja kamery (świat): auto dalej niż `smokeRange` nie dymi.
    func setSmoke(_ on: Bool, viewer: SIMD3<Float>? = nil) {
        var on = on && !Self.smokeOff
        if on, let viewer, simd_distance_squared(root.position(relativeTo: nil), viewer) > Self.smokeRange * Self.smokeRange {
            on = false
        }
        guard on != smoking else { return }
        debugLog("efekt: dym \(on)")
        smoking = on
    }

    /// Punkty, z których teraz dymi (przy tylnych kołach; oś Z do tyłu auta) — kłęby rysuje `DriftSmoke`.
    var smokeEmitters: [Entity] { smoking ? smoke : [] }

    func spinWheels(distance: Double) {
        let spin = simd_quatf(angle: Float(distance) / wheelRadius, axis: [1, 0, 0])
        let steer = simd_quatf(angle: steerAngle, axis: [0, 1, 0])
        for w in wheels { w.orientation = w.position.z > 0 ? steer * spin : spin }
    }

    /// Punkty styku tylnych kół z jezdnią (świat) — do śladów opon. Bez rozpoznanych kół: puste.
    func rearContacts() -> [SIMD3<Float>] {
        wheels.filter { $0.position.z < 0 }.map { $0.position(relativeTo: nil) }
    }

    // MARK: - Zawieszenie i skręt kół

    /// Kąt skrętu przednich kół (rad), przechył i pochylenie nadwozia — wygładzane jak na sprężynach.
    private(set) var steerAngle: Float = 0
    private var roll: Float = 0
    private var pitch: Float = 0
    private var lastSpeed: Double?

    /// Ruch nadwozia na zawieszeniu: w zakręcie przechyla się na zewnątrz, przy przyspieszaniu przysiada
    /// tyłem, przy hamowaniu nurkuje przodem. Przednie koła skręcają zgodnie z torem jazdy (Ackermann:
    /// kąt ≈ rozstaw osi × prędkość kątowa / prędkość), a w poślizgu kontrują.
    ///
    /// Nadwozie obraca się wokół osi kół (środek przechyłu), a koła zostają na jezdni — jak na
    /// prawdziwym zawieszeniu. Kąty jak w aucie drogowym przy ~1 g: przechył do 3,5°, pochylenie do 2°.
    ///
    /// `steerInput` (−1…1, dodatnie = w lewo; skręt gracza z `Car.lastSteer`) skręca przednie koła od razu
    /// po wciśnięciu — zanim auto zdąży zmienić tor jazdy; gdy tor skręca już mocniej, wygrywa Ackermann.
    func updateSuspension(yawRate: Double, speed: Double, slide: Double, dt: Double, steerInput: Double? = nil) {
        let accel = lastSpeed.map { (speed - $0) / max(dt, 1e-3) } ?? 0
        lastSpeed = speed
        let lateral = speed * yawRate
        let k = Float(1 - exp(-dt * 7))
        // W drifcie nadwozie dodatkowo kładzie się na zewnątrz poślizgu.
        let rollRaw: Double = -lateral * 0.0035 - slide * 0.05
        let rollTarget: Float = min(Self.maxRoll, max(-Self.maxRoll, Float(rollRaw)))
        let pitchTarget = Float(min(0.035, max(-0.035, -accel * 0.004)))
        roll += (rollTarget - roll) * k
        pitch += (pitchTarget - pitch) * k
        var ackermann = 2.7 * yawRate / max(speed, 3)
        if let steerInput {
            let wanted = max(-1, min(1, steerInput)) * Self.inputSteerAngle
            if abs(wanted) > abs(ackermann) { ackermann = wanted }
        }
        let steerTarget = Float(min(0.5, max(-0.5, ackermann - slide)))
        steerAngle += (steerTarget - steerAngle) * Float(1 - exp(-dt * 10))
        frame.transform = .identity
        for s in contactShadows where !s.isEnabled { s.isEnabled = true }
        let q = simd_quatf(angle: roll, axis: [0, 0, 1]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
        let pivot = SIMD3<Float>(0, wheelRadius, 0)
        body.orientation = q
        body.position = pivot - q.act(pivot)
    }

    static let maxRoll: Float = 0.06
    /// Kąt przednich kół (rad) przy pełnym wychyleniu skrętu gracza, zanim auto zacznie skręcać.
    static let inputSteerAngle = 0.3

    /// Przechył nadwozia względem kół (rad) — do testów.
    var bodyRoll: Float { roll }

    /// Rozbicie: koziołkuje całe auto razem z kołami. `t` — postęp 0…1.
    func setWreck(_ t: Float) {
        body.transform = .identity
        frame.orientation = simd_quatf(angle: t * .pi * 2, axis: [0, 1, 0])
            * simd_quatf(angle: sin(t * .pi * 2) * 0.8, axis: [0, 0, 1])
            * simd_quatf(angle: sin(t * .pi) * 0.6, axis: [1, 0, 0])
        frame.position = [0, sin(t * .pi) * 1.5, 0]
        // Auto w powietrzu — cień styku z jezdnią znika.
        for s in contactShadows where s.isEnabled { s.isEnabled = false }
    }

    /// Koła realistycznego modelu: części z „wheel/tire/rim/disc…” w nazwie (bez kierownicy i zacisków)
    /// grupujemy w cztery koła wg ćwiartki auta (`realisticWheelGroups`) i podpinamy pod osie w środkach kół,
    /// żeby się kręciły. Model, w którym koła to jedna wspólna siatka, zostaje bez zmian.
    /// Wzorce w `LocalAssets` są już scalone (`CarMeshMerge`) — każde koło to wtedy jedna–dwie encje.
    private func rigRealisticWheels(_ car: Entity, file: String) {
        guard let found = Self.realisticWheelGroups(car, space: root) else {
            debugLog("koła: \(file) — nie rozpoznano")
            return
        }
        let parts = found.flatMap { $0 }.map { (entity: $0, bounds: $0.visualBounds(relativeTo: root)) }
        var groups: [Int: [(entity: ModelEntity, bounds: BoundingBox)]] = [:]
        for (i, g) in found.enumerated() {
            groups[i] = g.map { (entity: $0, bounds: $0.visualBounds(relativeTo: root)) }
        }
        var radius: Float = 0
        var bottom = Float.greatestFiniteMagnitude
        for (_, group) in groups {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for p in group { lo = simd_min(lo, p.bounds.min); hi = simd_max(hi, p.bounds.max) }
            let pivot = Entity()
            frame.addChild(pivot)
            pivot.setPosition((lo + hi) / 2, relativeTo: root)
            for p in group { p.entity.setParent(pivot, preservingWorldTransform: true) }
            wheels.append(pivot)
            radius = max(radius, max(hi.y - lo.y, hi.z - lo.z) / 2)
            bottom = min(bottom, lo.y)
        }
        wheelRadius = max(0.2, radius)
        // Auto stoi na oponach: model wyrównano do najniższego punktu, a to bywa spojler albo osłona
        // podwozia — wtedy opony wiszą nad jezdnią albo w nią wchodzą. Dosuwamy spód opon do zera.
        if abs(bottom) > 0.003 {
            car.position.y -= bottom
            for w in wheels { w.position.y -= bottom }
        }
        debugLog(String(format: "koła: %@ — 4 koła z %d części, promień %.2f m, spód opon %.3f m", file, parts.count, wheelRadius, bottom))
        #if DEBUG || FAMILY
        if ProcessInfo.processInfo.arguments.contains("-logWheels") {
            debugLog("koła: \(file) części: " + Set(parts.map { String($0.entity.name.prefix(40)) }).sorted().joined(separator: ", "))
        }
        #endif
    }

    /// Części kół realistycznego modelu pogrupowane w cztery koła (wg ćwiartki auta w układzie `space`);
    /// nil, gdy nie wychodzą dokładnie cztery grupy. Wspólne dla scalania wzorca (`CarMeshMerge`)
    /// i dla osadzania kół na osiach — po scaleniu scalone koła muszą zostać rozpoznane tak samo.
    static func realisticWheelGroups(_ car: Entity, space: Entity) -> [[ModelEntity]]? {
        let wheelRx = try! NSRegularExpression(pattern: "wheel|tire|tyre|(?<![a-z])rims?(?![a-z])|disc|disk|reifen|felge", options: .caseInsensitive)
        let skipRx = try! NSRegularExpression(pattern: "steering|calip|brake|interior|INT_", options: .caseInsensitive)
        func has(_ rx: NSRegularExpression, _ s: String) -> Bool { rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        let carBounds = car.visualBounds(relativeTo: space)
        var parts: [(entity: ModelEntity, bounds: BoundingBox)] = []
        func walk(_ e: Entity, matched: Bool, skipped: Bool) {
            let m = matched || has(wheelRx, e.name)
            let sk = skipped || has(skipRx, e.name)
            if let model = e as? ModelEntity, m, !sk {
                let b = model.visualBounds(relativeTo: space)
                // Siatka obejmująca kilka kół naraz (szersza niż pół auta) — nie da się jej obracać.
                if b.extents.x < carBounds.extents.x * 0.45, b.extents.z < carBounds.extents.z * 0.35 {
                    parts.append((model, b))
                }
            }
            for c in e.children { walk(c, matched: m, skipped: sk) }
        }
        walk(car, matched: false, skipped: false)
        let cz = carBounds.center.z, cx = carBounds.center.x
        var groups: [Int: [ModelEntity]] = [:]
        var boxes: [Int: BoundingBox] = [:]
        for p in parts {
            let key = (p.bounds.center.x > cx ? 1 : 0) + (p.bounds.center.z > cz ? 2 : 0)
            groups[key, default: []].append(p.entity)
            boxes[key] = boxes[key].map { $0.union(p.bounds) } ?? p.bounds
        }
        guard groups.count == 4 else { return nil }
        // Części koła o nazwach spoza reguły (np. opona „Object_44” obok felgi „wheel”): bez tego zostawały
        // w nadwoziu — felga kręciła się i skręcała, a opona stała w miejscu, odklejona od felgi.
        // Należy do koła siatka okrągła w przekroju (wysokość ≈ długość), ze środkiem na osi koła
        // i nie większa niż półtora koła; zaciski hamulców są poza osią, więc zostają w nadwoziu.
        let taken = Set(parts.map { ObjectIdentifier($0.entity) })
        var extra: [String] = []
        func adopt(_ e: Entity, skipped: Bool) {
            let sk = skipped || has(skipRx, e.name)
            if let model = e as? ModelEntity, !sk, !taken.contains(ObjectIdentifier(model)) {
                let b = model.visualBounds(relativeTo: space)
                for (key, box) in boxes {
                    let r = max(box.extents.y, box.extents.z) / 2
                    let d = b.center - box.center
                    if r > 0.01, abs(d.y) < r * 0.12, abs(d.z) < r * 0.12, abs(d.x) < r,
                       abs(b.extents.y - b.extents.z) < max(b.extents.y, b.extents.z) * 0.12,
                       b.extents.y > r * 0.6, b.extents.y < r * 3, b.extents.x < r * 1.5 {
                        groups[key]!.append(model)
                        extra.append(e.name)
                        break
                    }
                }
            }
            for c in e.children { adopt(c, skipped: sk) }
        }
        adopt(car, skipped: false)
        if !extra.isEmpty { debugLog("koła: dołączone części spoza nazw: " + extra.prefix(12).joined(separator: ", ")) }
        return (0..<4).map { groups[$0]! }
    }
}

/// Gładka krzywa przez punkty (t, wartość) — interpolacja z wygładzeniem między sąsiednimi punktami.
func curve(_ t: Float, _ pts: [(Float, Float)]) -> Float {
    if t <= pts[0].0 { return pts[0].1 }
    for i in 1..<pts.count where t <= pts[i].0 {
        let (t0, v0) = pts[i - 1], (t1, v1) = pts[i]
        let u = (t - t0) / (t1 - t0)
        return v0 + (v1 - v0) * u * u * (3 - 2 * u)
    }
    return pts[pts.count - 1].1
}

func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let u = min(1, max(0, (x - a) / (b - a)))
    return u * u * (3 - 2 * u)
}
