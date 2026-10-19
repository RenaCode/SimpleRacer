import RealityKit
import UIKit

/// Ślady opon na asfalcie: za tylnymi kołami aut w poślizgu odkładają się czworokąty (pas o szerokości
/// opony), wszystkie w jednej siatce. Bufor cykliczny — najstarsze odcinki znikają, więc pamięć i koszt
/// rysowania są stałe. Siatka przebudowuje się 10 razy na sekundę, nie co klatkę.
@MainActor
final class SkidMarks {
    let entity = ModelEntity()

    private static let maxSegments = 700
    private static let halfWidth: Float = 0.13
    /// Tuż nad jezdnią i liniami (jezdnia y 0,02, linie 0,04).
    private static let height: Float = 0.047

    private var segments: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
    private var next = 0
    private var last: [Int: SIMD3<Float>] = [:]
    private var live: [Int: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [:]
    /// Odcinki dodane od ostatniej przebudowy historii — rysowane w małej siatce co klatkę.
    private var pending: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
    /// Krótkie odcinki przy kołach, przebudowywane co klatkę.
    let liveEntity = ModelEntity()
    private var dirty = false
    private var timer = 0.0
    private let material: UnlitMaterial

    init() {
        entity.addChild(liveEntity)
        var m = UnlitMaterial(color: UIColor(white: 0.04, alpha: 1))
        if let mask = Self.mask(),
           let tex = try? TextureResource(image: mask, options: .init(semantic: .raw, mipmapsMode: .allocateAndGenerateAll)) {
            m.blending = .transparent(opacity: .init(scale: 0.6, texture: .init(tex)))
        } else {
            m.blending = .transparent(opacity: .init(floatLiteral: 0.45))
        }
        material = m
    }

    /// `key` — stały numer koła (auto × 4 + koło); `active` — czy opona teraz ślizga się po asfalcie.
    func track(key: Int, at p: SIMD3<Float>, active: Bool) {
        guard active else { last[key] = nil; live[key] = nil; return }
        let point = SIMD3<Float>(p.x, Self.height, p.z)
        guard let previous = last[key] else { last[key] = point; return }
        let d = simd_distance(previous, point)
        // Odcinek od ostatniego zapisanego punktu do koła — rysowany co klatkę, żeby ślad zaczynał się
        // tuż pod oponą (historia przebudowuje się rzadziej).
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
        pending.append(quad)
        if segments.count < Self.maxSegments {
            segments.append(quad)
        } else {
            segments[next] = quad
            next = (next + 1) % Self.maxSegments
        }
        last[key] = point
        dirty = true
    }

    func flush(dt: Double) {
        var lb = MeshBuilder()
        for (a, c, e, f) in pending + Array(live.values) {
            lb.quad(a, c, e, f, uv: [[0, 0], [1, 0], [1, 1], [0, 1]], doubleSided: true)
        }
        if lb.isEmpty {
            liveEntity.isEnabled = false
        } else if let mesh = try? lb.mesh(name: "skid-live") {
            liveEntity.isEnabled = true
            if liveEntity.model == nil {
                liveEntity.model = ModelComponent(mesh: mesh, materials: [material])
            } else {
                liveEntity.model?.mesh = mesh
            }
        }
        timer -= dt
        guard dirty, timer <= 0 else { return }
        timer = 0.25
        dirty = false
        pending.removeAll(keepingCapacity: true)
        var b = MeshBuilder()
        for (a, c, e, f) in segments {
            b.quad(a, c, e, f, uv: [[0, 0], [1, 0], [1, 1], [0, 1]], doubleSided: true)
        }
        guard let mesh = try? b.mesh(name: "skid-marks") else { return }
        if entity.model == nil {
            entity.model = ModelComponent(mesh: mesh, materials: [material])
        } else {
            entity.model?.mesh = mesh
        }
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
