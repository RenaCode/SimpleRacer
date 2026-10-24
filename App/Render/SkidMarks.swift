import RealityKit
import UIKit

/// Ślady opon na asfalcie: za tylnymi kołami aut w poślizgu odkładają się czworokąty (pas o szerokości
/// opony). Wszystkie leżą w jednej siatce `LowLevelMesh` o stałej pojemności — bufor cykliczny: nowy
/// odcinek nadpisuje najstarszy w miejscu (4 wierzchołki), bez budowania siatki od nowa. Krótkie odcinki
/// od ostatniego punktu do koła (żeby ślad zaczynał się tuż pod oponą) to druga, mała siatka
/// przepisywana co klatkę.
@MainActor
final class SkidMarks {
    let entity = ModelEntity()
    /// Krótkie odcinki przy kołach, przepisywane co klatkę.
    let liveEntity = ModelEntity()

    private static let maxSegments = 700
    private static let maxLive = 48
    private static let halfWidth: Float = 0.13
    /// Nad jezdnią (0,02), liniami (0,028) i cieniem kontaktowym aut (0,032–0,033) — odstępy ≥ 3 mm.
    private static let height: Float = 0.036

    typealias Quad = (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)

    private var last: [Int: SIMD3<Float>] = [:]
    private var live: [Int: Quad] = [:]
    private var next = 0
    private var filled = 0
    private let history: LowLevelMesh?
    private let liveMesh: LowLevelMesh?

    /// Wierzchołek w buforze: pozycja, normalna, UV (32 bajty, bez wyrównania SIMD3).
    private struct Vertex {
        var px, py, pz, nx, ny, nz, u, v: Float
    }

    init() {
        entity.addChild(liveEntity)
        var m = UnlitMaterial(color: UIColor(white: 0.04, alpha: 1))
        if let mask = Self.mask(),
           let tex = try? TextureResource(image: mask, options: .init(semantic: .raw, mipmapsMode: .allocateAndGenerateAll)) {
            m.blending = .transparent(opacity: .init(scale: 0.6, texture: .init(tex)))
        } else {
            m.blending = .transparent(opacity: .init(floatLiteral: 0.45))
        }
        history = Self.makeMesh(quads: Self.maxSegments)
        liveMesh = Self.makeMesh(quads: Self.maxLive)
        if let history, let mesh = try? MeshResource(from: history) {
            entity.model = ModelComponent(mesh: mesh, materials: [m])
        }
        if let liveMesh, let mesh = try? MeshResource(from: liveMesh) {
            liveEntity.model = ModelComponent(mesh: mesh, materials: [m])
        }
        liveEntity.isEnabled = false
    }

    /// Siatka na `quads` czworokątów z gotowymi indeksami (obie strony — widać ją z każdej strony),
    /// wierzchołki na start zerowe (zdegenerowane trójkąty nic nie rysują).
    private static func makeMesh(quads: Int) -> LowLevelMesh? {
        let desc = LowLevelMesh.Descriptor(
            vertexCapacity: quads * 4,
            vertexAttributes: [
                .init(semantic: .position, format: .float3, offset: 0),
                .init(semantic: .normal, format: .float3, offset: 12),
                .init(semantic: .uv0, format: .float2, offset: 24),
            ],
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)],
            indexCapacity: quads * 12,
            indexType: .uint32)
        guard let mesh = try? LowLevelMesh(descriptor: desc) else { return nil }
        let order: [UInt32] = [0, 1, 2, 0, 2, 3, 0, 2, 1, 0, 3, 2]
        mesh.withUnsafeMutableIndices { raw in
            let idx = raw.bindMemory(to: UInt32.self)
            for q in 0..<quads {
                for k in 0..<12 { idx[q * 12 + k] = UInt32(q * 4) + order[k] }
            }
        }
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
        }
        // Część z jednym zdegenerowanym trójkątem: pusta siatka bywa odrzucana przy tworzeniu zasobu.
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: 3, bounds: bounds)])
        return mesh
    }

    private static let bounds = BoundingBox(min: [-20_000, -1, -20_000], max: [20_000, 1, 20_000])

    private static func write(_ q: Quad, into v: UnsafeMutableBufferPointer<Vertex>, slot: Int) {
        // Cztery narożniki wprost, bez tablicy pomocniczej (co klatkę dla każdego koła w drifcie).
        func put(_ k: Int, _ p: SIMD3<Float>, _ u: Float, _ w: Float) {
            v[slot * 4 + k] = Vertex(px: p.x, py: p.y, pz: p.z, nx: 0, ny: 1, nz: 0, u: u, v: w)
        }
        put(0, q.0, 0, 0)
        put(1, q.1, 1, 0)
        put(2, q.2, 1, 1)
        put(3, q.3, 0, 1)
    }

    /// `key` — stały numer koła (auto × 4 + koło); `active` — czy opona teraz ślizga się po asfalcie.
    func track(key: Int, at p: SIMD3<Float>, active: Bool) {
        guard active else { last[key] = nil; live[key] = nil; return }
        let point = SIMD3<Float>(p.x, Self.height, p.z)
        guard let previous = last[key] else { last[key] = point; return }
        let d = simd_distance(previous, point)
        // Odcinek od ostatniego zapisanego punktu do koła — rysowany co klatkę, żeby ślad zaczynał się
        // tuż pod oponą.
        if d >= 0.05 && d <= 4 {
            let dir = (point - previous) / d
            let side = SIMD3<Float>(dir.z, 0, -dir.x) * Self.halfWidth
            live[key] = (previous - side, previous + side, point + side, point - side)
        }
        if d < 2.5 { return }
        if d > 4 { last[key] = point; return } // przeskok (np. reset po rozbiciu) — bez kreski przez pół toru
        let dir = (point - previous) / d
        let side = SIMD3<Float>(dir.z, 0, -dir.x) * Self.halfWidth
        let quad = (previous - side, previous + side, point + side, point - side)
        // Nowy odcinek od razu w buforze cyklicznym (nadpisuje najstarszy) — 4 wierzchołki, bez przebudowy.
        if let history {
            let slot = next
            history.withUnsafeMutableBytes(bufferIndex: 0) { raw in
                Self.write(quad, into: raw.bindMemory(to: Vertex.self), slot: slot)
            }
            next = (next + 1) % Self.maxSegments
            if filled < Self.maxSegments {
                filled += 1
                history.parts.replaceAll([LowLevelMesh.Part(indexCount: filled * 12, bounds: Self.bounds)])
            }
        }
        live[key] = nil
        last[key] = point
    }

    /// Raz na klatkę: przepisuje krótkie odcinki przy kołach.
    func flush(dt: Double) {
        guard let liveMesh else { return }
        if live.isEmpty {
            if liveEntity.isEnabled { liveEntity.isEnabled = false }
            return
        }
        var count = 0
        liveMesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let v = raw.bindMemory(to: Vertex.self)
            for q in live.values where count < Self.maxLive {
                Self.write(q, into: v, slot: count)
                count += 1
            }
        }
        liveMesh.parts.replaceAll([LowLevelMesh.Part(indexCount: count * 12, bounds: Self.bounds)])
        if !liveEntity.isEnabled { liveEntity.isEnabled = true }
    }

    /// Przekrój śladu: ciemny środek, miękkie brzegi, podłużne smugi bieżnika.
    private static func mask() -> CGImage? {
        let w = 64, h = 16
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        for x in 0..<w {
            let t = Double(x) / Double(w - 1)
            let edge = sin(t * .pi) // 0 na brzegach, 1 w środku
            let groove = (x / 6) % 2 == 0 ? 1.0 : 0.75
            ctx.setFillColor(gray: CGFloat(min(1, edge * 1.3) * groove), alpha: 1)
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
        }
        return ctx.makeImage()
    }
}
