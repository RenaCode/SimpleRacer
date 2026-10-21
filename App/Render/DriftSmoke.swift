import RealityKit
import UIKit

/// Dym spod opon w drifcie: kłęby to czworokąty zwrócone do kamery, wszystkie w jednej siatce
/// `LowLevelMesh` przepisywanej co klatkę (jak ślady opon), ruch liczony na CPU.
///
/// Zastępuje `ParticleEmitterComponent`: na iOS 27 każdy pracujący emiter RealityKit zbijał wyścig do
/// 12–15 kl./s niezależnie od liczby i rozmiaru cząsteczek (5 cząsteczek/s kosztowało tyle co 110),
/// a dymiło kilka aut naraz. Tu koszt to ~1500 czworokątów zapisanych w bufor — ułamek milisekundy.
///
/// Wygasanie: `UnlitMaterial` nie zna koloru wierzchołka, więc przezroczystość kłębu bierzemy z paska
/// 16 kopii tekstury o malejącej gęstości — wiek cząsteczki wybiera kopię przez UV.
@MainActor
final class DriftSmoke {
    let entity = ModelEntity()

    /// Parametry jak w dawnym emiterze: na sekundę z każdego koła, życie, rozmiar na starcie i mnożnik na końcu.
    private static let birthRate: Float = 110
    private static let lifeSpan: Float = 0.8
    private static let lifeSpanVariation: Float = 0.25
    private static let size: Float = 0.6
    private static let sizeVariation: Float = 0.2
    private static let sizeAtEnd: Float = 2.8
    private static let speed: Float = 0.8
    private static let speedVariation: Float = 0.4
    /// Połowa kąta stożka, w którym kłęby wylatują w górę (rad).
    private static let spreadingAngle: Float = 0.8
    /// Unoszenie się dymu (m/s²).
    private static let lift: Float = 0.9
    private static let angularSpeedVariation: Float = 1.2
    /// Pudełko narodzin w układzie emitera (oś Z do tyłu auta): cząsteczki rodzą się na całej drodze,
    /// którą koło przebyło w klatce, więc przy dużej prędkości smuga jest ciągła.
    private static let box = SIMD3<Float>(0.25, 0.05, 1.4)
    private static let capacity = 1536
    private static let fadeSteps = 16

    private struct Puff {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var age: Float
        var life: Float
        var size: Float
        var angle: Float
        var spin: Float
    }

    /// Wierzchołek w buforze: pozycja, normalna, UV (32 bajty, bez wyrównania SIMD3).
    private struct Vertex {
        var px, py, pz, nx, ny, nz, u, v: Float
    }

    private var puffs: [Puff] = []
    /// Ułamek cząsteczki „do urodzenia” per emiter — przy 60 kl./s na klatkę wypada ~1,8 kłębu.
    private var pending: [ObjectIdentifier: Float] = [:]
    private let mesh: LowLevelMesh?
    private var rng = SystemRandomNumberGenerator()

    init() {
        puffs.reserveCapacity(Self.capacity)
        mesh = Self.makeMesh()
        var m = UnlitMaterial(color: UIColor(white: Self.tint, alpha: 1))
        if let tex = ParticleTextures.smokeFadeStrip(steps: Self.fadeSteps) {
            m.blending = .transparent(opacity: .init(scale: Self.opacity, texture: .init(tex)))
        } else {
            m.blending = .transparent(opacity: .init(floatLiteral: Self.opacity * 0.3))
        }
        // Przezroczyste kłęby nie zapisują głębi — inaczej bliższy ucinałby dalsze prostą krawędzią.
        m.writesDepth = false
        if let mesh, let resource = try? MeshResource(from: mesh) {
            entity.model = ModelComponent(mesh: resource, materials: [m])
        }
        entity.isEnabled = false
    }

    #if DEBUG || FAMILY
    /// `-smokeLook tint,opacity` — strojenie wyglądu bez przebudowy (zrzuty A/B ze starym dymem).
    private static let look: [Float] = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-smokeLook"), i + 1 < args.count else { return [] }
        let v = args[i + 1].split(separator: ",").compactMap { Float($0) }
        return v.count == 2 ? v : []
    }()
    private static var tint: CGFloat { CGFloat(look.first ?? 0.9) }
    private static var opacity: Float { look.last ?? 0.22 }
    #else
    private static let tint: CGFloat = 0.9
    private static let opacity: Float = 0.22
    #endif

    private static func makeMesh() -> LowLevelMesh? {
        let desc = LowLevelMesh.Descriptor(
            vertexCapacity: capacity * 4,
            vertexAttributes: [
                .init(semantic: .position, format: .float3, offset: 0),
                .init(semantic: .normal, format: .float3, offset: 12),
                .init(semantic: .uv0, format: .float2, offset: 24),
            ],
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)],
            indexCapacity: capacity * 6,
            indexType: .uint32)
        guard let mesh = try? LowLevelMesh(descriptor: desc) else { return nil }
        let order: [UInt32] = [0, 1, 2, 0, 2, 3]
        mesh.withUnsafeMutableIndices { raw in
            let idx = raw.bindMemory(to: UInt32.self)
            for q in 0..<capacity {
                for k in 0..<6 { idx[q * 6 + k] = UInt32(q * 4) + order[k] }
            }
        }
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
        }
        // Część z jednym zdegenerowanym trójkątem: pusta siatka bywa odrzucana przy tworzeniu zasobu.
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: 3, bounds: BoundingBox(min: [-1, -1, -1], max: [1, 1, 1]))])
        return mesh
    }

    private func random(_ range: ClosedRange<Float>) -> Float { Float.random(in: range, using: &rng) }

    /// Kłęby z emiterów (`Entity` przy tylnych kołach; oś Z do tyłu auta) w tej klatce.
    func emit(from emitters: [Entity], dt: Float) {
        for e in emitters {
            let id = ObjectIdentifier(e)
            var n = (pending[id] ?? 0) + Self.birthRate * dt
            let m = e.transformMatrix(relativeTo: nil)
            while n >= 1 {
                n -= 1
                guard puffs.count < Self.capacity else { continue }
                let local = SIMD4<Float>(random(-0.5...0.5) * Self.box.x, random(-0.5...0.5) * Self.box.y,
                                         random(-0.5...0.5) * Self.box.z, 1)
                let p = m * local
                // Kierunek w stożku wokół osi Y (świat), równomiernie po kącie bryłowym.
                let cosA = random(cos(Self.spreadingAngle)...1)
                let sinA = (1 - cosA * cosA).squareRoot()
                let phi = random(0...(2 * .pi))
                let dir = SIMD3<Float>(sinA * cos(phi), cosA, sinA * sin(phi))
                let life = Self.lifeSpan + random(-Self.lifeSpanVariation...Self.lifeSpanVariation)
                puffs.append(Puff(position: [p.x, p.y, p.z],
                                  velocity: dir * (Self.speed + random(-Self.speedVariation...Self.speedVariation)),
                                  age: 0, life: max(0.1, life),
                                  size: Self.size + random(-Self.sizeVariation...Self.sizeVariation),
                                  angle: random(-.pi ... .pi),
                                  spin: random(-Self.angularSpeedVariation...Self.angularSpeedVariation)))
            }
            pending[id] = n
        }
    }

    /// Raz na klatkę, po `emit`: ruch, starzenie i przepisanie czworokątów zwróconych do kamery.
    func update(dt: Float, camera: Entity) {
        guard let mesh else { return }
        var i = 0
        while i < puffs.count {
            puffs[i].age += dt
            if puffs[i].age >= puffs[i].life {
                puffs.swapAt(i, puffs.count - 1)
                puffs.removeLast()
                continue
            }
            puffs[i].velocity.y += Self.lift * dt
            puffs[i].position += puffs[i].velocity * dt
            puffs[i].angle += puffs[i].spin * dt
            i += 1
        }
        if puffs.isEmpty {
            if entity.isEnabled { entity.isEnabled = false }
            pending.removeAll()
            return
        }
        let q = camera.orientation(relativeTo: nil)
        let right = q.act([1, 0, 0]), up = q.act([0, 1, 0]), toCamera = q.act([0, 0, 1])
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        let steps = Float(Self.fadeSteps)
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let v = raw.bindMemory(to: Vertex.self)
            for (k, p) in puffs.enumerated() {
                let t = p.age / p.life
                // Rozmiar rośnie liniowo do `sizeAtEnd`; promień = połowa boku.
                let r = p.size * (1 + (Self.sizeAtEnd - 1) * t) * 0.5
                let c = cos(p.angle), s = sin(p.angle)
                let a = (right * c + up * s) * r, b = (up * c - right * s) * r
                // Wygasanie liniowe: kopia paska o gęstości 1 − t.
                let cell = min(steps - 1, (t * steps).rounded(.down))
                let u0 = cell / steps, u1 = (cell + 1) / steps
                let corners = [(p.position - a - b, u0, Float(1)), (p.position + a - b, u1, Float(1)),
                               (p.position + a + b, u1, Float(0)), (p.position - a + b, u0, Float(0))]
                for (j, corner) in corners.enumerated() {
                    v[k * 4 + j] = Vertex(px: corner.0.x, py: corner.0.y, pz: corner.0.z,
                                          nx: toCamera.x, ny: toCamera.y, nz: toCamera.z, u: corner.1, v: corner.2)
                }
                lo = simd_min(lo, p.position - r * 1.5)
                hi = simd_max(hi, p.position + r * 1.5)
            }
        }
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: puffs.count * 6, bounds: BoundingBox(min: lo, max: hi))])
        if !entity.isEnabled { entity.isEnabled = true }
    }
}
