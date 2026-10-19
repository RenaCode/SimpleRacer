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
    /// Nadwozie — przechyla się w drifcie i koziołkuje przy rozbiciu.
    let body = Entity()
    private var paintParts: [ModelEntity] = []
    private var flames: [ModelEntity] = []
    private var flameEmitters: [Entity] = []
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
        root.addChild(body)
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
                root.addChild(wheel)
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
                root.addChild(pivot)
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

    /// Realistyczny model USDZ (już znormalizowany): klon współdzielący siatki i tekstury wzorca.
    /// Lakier to siatki o nazwach z `paintParts` (dokładne nazwy prim USD przypiętych do materiału lakieru).
    private func buildRealistic(template: Entity, ref: RealisticModelRef, color: UIColor) -> ModelDims {
        let car = template.clone(recursive: true)
        body.addChild(car)
        let names = Set(ref.paintParts)
        func walk(_ e: Entity, inPaint: Bool) {
            let hit = inPaint || names.contains(e.name)
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
            p.baseColor = .init(tint: color)
            p.metallic = 0.45
            p.roughness = 0.28
            p.clearcoat = 1.0
            p.clearcoatRoughness = 0.04
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

    /// Płomień nitro z wydechów (jasny rdzeń + strumień świecących cząsteczek) i dym spod tylnych kół.
    private func addEffects(width W: Float, rearZ: Float, exhaustY: Float, backWheelX: Float, backWheelZ: Float) {
        // Rdzeń: wydłużona, świecąca „kula” tuż za wydechem; strumień cząsteczek leci z niej do tyłu.
        let coreMesh = MeshResource.generateSphere(radius: 0.08)
        for side: Float in [-1, 1] {
            let exhaust = Entity()
            exhaust.position = [side * W * 0.2, exhaustY, rearZ - 0.15]
            let core = ModelEntity(mesh: coreMesh, materials: [Self.flame(.normal)])
            core.scale = [1, 1, 2.2]
            core.position.z = -0.25
            exhaust.addChild(core)
            var emitter = Self.flameEmitter(.normal)
            emitter.isEmitting = false
            exhaust.components.set(emitter)
            core.isEnabled = false
            body.addChild(exhaust)
            flames.append(core)
            flameEmitters.append(exhaust)
        }
        for sx: Float in [-1, 1] {
            let e = Entity()
            e.position = [sx * backWheelX, 0.15, backWheelZ - 0.5]
            e.components.set(Self.smokeEmitter())
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

    private static func smokeEmitter() -> ParticleEmitterComponent {
        var p = ParticleEmitterComponent()
        // Pudełko wydłużone do tyłu: cząsteczki rodzą się na całej drodze, którą koło przebyło w klatce,
        // więc przy dużej prędkości smuga jest ciągła, a nie z osobnych kłębów.
        p.emitterShape = .box
        p.emitterShapeSize = [0.25, 0.05, 1.4]
        p.birthLocation = .volume
        p.speed = 0.8
        p.speedVariation = 0.4
        p.particlesInheritTransform = false
        // Mało, ale dużych i krótko żyjących cząsteczek: półprzezroczysty dym nakłada się na siebie
        // przed kamerą i to on (nie płomień) przycinał obraz, gdy kilka aut driftowało naraz.
        // Gęsta, rzadka smuga zamiast pojedynczych kłębów: dużo słabo kryjących cząsteczek, które rosną
        // i rozmywają się w powietrzu (przy 200 km/h auto przejeżdża metr na klatkę).
        p.mainEmitter.birthRate = 110
        p.mainEmitter.lifeSpan = 0.8
        p.mainEmitter.lifeSpanVariation = 0.25
        p.mainEmitter.size = 0.7
        p.mainEmitter.sizeVariation = 0.25
        p.mainEmitter.sizeMultiplierAtEndOfLifespan = 3.2
        p.mainEmitter.spreadingAngle = 0.8
        p.mainEmitter.color = .constant(.single(UIColor(white: 0.88, alpha: 0.1)))
        p.mainEmitter.opacityCurve = .linearFadeOut
        p.isEmitting = false
        return p
    }

    /// Kolor płomienia: niebieski (nitro), fioletowy (perfect), pomarańczowy (fala).
    private static func flameColor(_ mode: NitroMode) -> UIColor {
        switch mode {
        case .off, .normal: UIColor(red: 0.25, green: 0.65, blue: 1, alpha: 1)
        case .perfect: UIColor(red: 0.8, green: 0.25, blue: 1, alpha: 1)
        case .shockwave: UIColor(red: 1, green: 0.55, blue: 0.1, alpha: 1)
        }
    }

    /// Rdzeń płomienia: jasny kolor trybu (biel na ciemnym asfalcie wychodziła szaro), półprzezroczysty.
    private static var flameMaterials: [NitroMode: UnlitMaterial] = [:]
    private static var flameEmitterCache: [NitroMode: ParticleEmitterComponent] = [:]

    private static func flame(_ mode: NitroMode) -> UnlitMaterial {
        if let m = flameMaterials[mode] { return m }
        let m = makeFlame(mode)
        flameMaterials[mode] = m
        return m
    }

    private static func flameEmitter(_ mode: NitroMode) -> ParticleEmitterComponent {
        if let p = flameEmitterCache[mode] { return p }
        let p = makeFlameEmitter(mode)
        flameEmitterCache[mode] = p
        return p
    }

    private static func makeFlame(_ mode: NitroMode) -> UnlitMaterial {
        let c = flameColor(mode)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        var m = UnlitMaterial(color: UIColor(red: 0.35 + r * 0.65, green: 0.35 + g * 0.65, blue: 0.35 + b * 0.65, alpha: 1))
        m.blending = .transparent(opacity: .init(floatLiteral: 0.75))
        return m
    }

    /// Strumień płomienia: krótko żyjące, świecące (addytywne) cząsteczki, od białego żaru do koloru trybu.
    private static func makeFlameEmitter(_ mode: NitroMode) -> ParticleEmitterComponent {
        var p = ParticleEmitterComponent()
        p.emitterShape = .point
        p.birthDirection = .local
        p.emissionDirection = [0, 0, -1]
        p.speed = 13
        p.speedVariation = 2
        p.particlesInheritTransform = true // płomień trzyma się auta, nie zostaje na drodze
        // Wąski u wydechu, rozszerza się i ciemnieje — smuga ognia, a nie kłęby.
        p.mainEmitter.birthRate = 320
        p.mainEmitter.lifeSpan = 0.11
        p.mainEmitter.lifeSpanVariation = 0.03
        p.mainEmitter.size = mode == .shockwave ? 0.2 : 0.14
        p.mainEmitter.sizeMultiplierAtEndOfLifespan = 1.8
        p.mainEmitter.spreadingAngle = 0.08
        p.mainEmitter.blendMode = .additive
        let c = flameColor(mode)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        let hot = UIColor(red: 0.5 + r * 0.5, green: 0.5 + g * 0.5, blue: 0.5 + b * 0.5, alpha: 0.9)
        let cool = UIColor(red: r * 0.6, green: g * 0.6, blue: b * 0.8, alpha: 0.2)
        p.mainEmitter.color = .evolving(start: .single(hot), end: .single(cool))
        p.mainEmitter.opacityCurve = .linearFadeOut
        return p
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

    func setFlame(_ mode: NitroMode) {
        if mode != flameMode {
            // Emiter żyje cały wyścig; przy zmianie trybu podmieniamy gotowy (zbuforowany) komponent,
            // a przy wyłączeniu tylko wstrzymujemy emisję — tworzenie emiterów w biegu dawało przycięcia.
            let colourChanged = mode != .off && flameColorKey(mode) != flameColorKey(lastFlameColor)
            debugLog("efekt: nitro \(mode)")
            flameMode = mode
            for e in flameEmitters {
                var p = colourChanged ? Self.flameEmitter(mode) : (e.components[ParticleEmitterComponent.self] ?? Self.flameEmitter(mode))
                p.isEmitting = mode != .off
                e.components.set(p)
            }
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
        // Migotanie rdzenia: płomień „oddycha”.
        let base: Float = mode == .shockwave ? 1.4 : mode == .perfect ? 1.2 : 1
        for f in flames {
            let k = Float.random(in: 0.8...1.2)
            f.scale = [base * k, base * k, base * 2.2 * Float.random(in: 0.85...1.25)]
        }
    }

    private var lastFlameColor: NitroMode = .normal
    private func flameColorKey(_ m: NitroMode) -> NitroMode { m == .off ? .normal : m }

    func setSmoke(_ on: Bool) {
        guard on != smoking else { return }
        debugLog("efekt: dym \(on)")
        smoking = on
        for e in smoke {
            guard var p = e.components[ParticleEmitterComponent.self] else { continue }
            p.isEmitting = on
            e.components.set(p)
        }
    }

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
    /// Zwraca obrót nadwozia (bez przechyłu w drifcie, który dokłada RaceGame).
    func chassis(yawRate: Double, speed: Double, slide: Double, dt: Double) -> simd_quatf {
        let accel = lastSpeed.map { (speed - $0) / max(dt, 1e-3) } ?? 0
        lastSpeed = speed
        let lateral = speed * yawRate
        let k = Float(1 - exp(-dt * 7))
        let rollTarget = Float(min(0.07, max(-0.07, -lateral * 0.0035)))
        let pitchTarget = Float(min(0.035, max(-0.035, -accel * 0.004)))
        roll += (rollTarget - roll) * k
        pitch += (pitchTarget - pitch) * k
        let ackermann = 2.7 * yawRate / max(speed, 3)
        let steerTarget = Float(min(0.5, max(-0.5, ackermann - slide)))
        steerAngle += (steerTarget - steerAngle) * Float(1 - exp(-dt * 10))
        return simd_quatf(angle: roll, axis: [0, 0, 1]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
    }

    /// Koła realistycznego modelu: części z „wheel/tire/rim/disc…” w nazwie (bez kierownicy i zacisków)
    /// grupujemy w cztery koła wg ćwiartki auta i podpinamy pod osie w środkach kół, żeby się kręciły.
    /// Model, w którym koła to jedna wspólna siatka, zostaje bez zmian.
    private func rigRealisticWheels(_ car: Entity, file: String) {
        let wheelRx = try! NSRegularExpression(pattern: "wheel|tire|tyre|(?<![a-z])rims?(?![a-z])|disc|disk|reifen|felge", options: .caseInsensitive)
        let skipRx = try! NSRegularExpression(pattern: "steering|caliper|brake|interior|INT_", options: .caseInsensitive)
        func has(_ rx: NSRegularExpression, _ s: String) -> Bool { rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        let carBounds = car.visualBounds(relativeTo: root)
        var parts: [(entity: ModelEntity, bounds: BoundingBox)] = []
        func walk(_ e: Entity, matched: Bool, skipped: Bool) {
            let m = matched || has(wheelRx, e.name)
            let sk = skipped || has(skipRx, e.name)
            if let model = e as? ModelEntity, m, !sk {
                let b = model.visualBounds(relativeTo: root)
                // Siatka obejmująca kilka kół naraz (szersza niż pół auta) — nie da się jej obracać.
                if b.extents.x < carBounds.extents.x * 0.45, b.extents.z < carBounds.extents.z * 0.35 {
                    parts.append((model, b))
                }
            }
            for c in e.children { walk(c, matched: m, skipped: sk) }
        }
        walk(car, matched: false, skipped: false)
        let cz = carBounds.center.z, cx = carBounds.center.x
        var groups: [Int: [(entity: ModelEntity, bounds: BoundingBox)]] = [:]
        for p in parts {
            let key = (p.bounds.center.x > cx ? 1 : 0) + (p.bounds.center.z > cz ? 2 : 0)
            groups[key, default: []].append(p)
        }
        guard groups.count == 4 else {
            debugLog("koła: \(file) — nie rozpoznano (\(parts.count) części, \(groups.count) grup)")
            return
        }
        var radius: Float = 0
        for (_, group) in groups {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for p in group { lo = simd_min(lo, p.bounds.min); hi = simd_max(hi, p.bounds.max) }
            let pivot = Entity()
            body.addChild(pivot)
            pivot.setPosition((lo + hi) / 2, relativeTo: root)
            for p in group { p.entity.setParent(pivot, preservingWorldTransform: true) }
            wheels.append(pivot)
            radius = max(radius, max(hi.y - lo.y, hi.z - lo.z) / 2)
        }
        wheelRadius = max(0.2, radius)
        debugLog(String(format: "koła: %@ — 4 koła z %d części, promień %.2f m", file, parts.count, wheelRadius))
        #if DEBUG || FAMILY
        if ProcessInfo.processInfo.arguments.contains("-logWheels") {
            debugLog("koła: \(file) części: " + Set(parts.map { String($0.entity.name.prefix(40)) }).sorted().joined(separator: ", "))
        }
        #endif
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
