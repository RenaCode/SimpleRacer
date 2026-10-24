import Foundation
import simd

public struct TrackSample {
    public var x: Double
    public var z: Double
    /// Kierunek osi trasy; wektor jazdy to (sin h, cos h) w płaszczyźnie XZ. Rośnie przy skręcie w lewo.
    public var heading: Double
    /// Krzywizna 1/m, dodatnia dla zakrętu w lewo.
    public var curvature: Double
}

/// Zamknięta trasa we współrzędnych trasy: `s` — odległość wzdłuż osi (m), `d` — przesunięcie w bok
/// od osi (m, dodatnie w lewo). Fizyka liczy się w (s, d), dzięki czemu bandy, kolejność w wyścigu
/// i jazda rywali są proste.
public final class Track {
    public let length: Double
    public let ds: Double
    public let count: Int
    public let halfWidth: Double
    private var xs: [Double]
    private var zs: [Double]
    private var hs: [Double]
    private var ks: [Double]

    public init(points: [SIMD2<Double>], halfWidth: Double) {
        self.halfWidth = halfWidth
        let dense = Track.centripetalCatmullRom(Track.withoutRepeats(points), samplesPerSegment: 200)

        // Długość łuku wzdłuż gęstej łamanej, potem próbki co ~1 m.
        var cum = [0.0]
        for i in 1..<dense.count { cum.append(cum[i - 1] + simd_distance(dense[i - 1], dense[i])) }
        let total = cum.last!
        let n = max(64, Int((total).rounded()))
        length = total
        count = n
        ds = total / Double(n)

        xs = []; zs = []
        var j = 0
        for i in 0..<n {
            let target = Double(i) * ds
            while j < cum.count - 2 && cum[j + 1] < target { j += 1 }
            let f = (target - cum[j]) / max(1e-9, cum[j + 1] - cum[j])
            let p = dense[j] + (dense[j + 1] - dense[j]) * f
            xs.append(p.x); zs.append(p.y)
        }

        hs = Array(repeating: 0, count: n)
        for i in 0..<n {
            let a = (i - 1 + n) % n, b = (i + 1) % n
            hs[i] = atan2(xs[b] - xs[a], zs[b] - zs[a])
        }
        var raw = Array(repeating: 0.0, count: n)
        for i in 0..<n {
            let a = (i - 1 + n) % n, b = (i + 1) % n
            raw[i] = wrapAngle(hs[b] - hs[a]) / (2 * ds)
        }
        // Lekkie wygładzenie, żeby szum próbkowania nie szarpał autami.
        let w = 4
        ks = (0..<n).map { i in
            var sum = 0.0
            for k in -w...w { sum += raw[(i + k + n) % n] }
            return sum / Double(2 * w + 1)
        }
    }

    public func sample(at s: Double) -> TrackSample {
        // NaN/∞ (np. z auta o zerowej prędkości maksymalnej) — `Int(u)` niżej przerwałoby program.
        let u = s.isFinite ? wrap(s, length) / ds : 0
        let i = Int(u) % count
        let j = (i + 1) % count
        let f = u - floor(u)
        return TrackSample(
            x: lerp(xs[i], xs[j], f),
            z: lerp(zs[i], zs[j], f),
            heading: hs[i] + wrapAngle(hs[j] - hs[i]) * f,
            curvature: lerp(ks[i], ks[j], f)
        )
    }

    /// Współrzędne trasy → świat. Wektor „w lewo” od osi to (cos h, −sin h).
    public func toWorld(s: Double, d: Double) -> (x: Double, z: Double, heading: Double) {
        let p = sample(at: s)
        return (p.x + d * cos(p.heading), p.z - d * sin(p.heading), p.heading)
    }

    /// Najmniejsza odległość punktu świata od osi trasy (do rozstawiania dekoracji).
    public func distanceToAxis(x: Double, z: Double) -> Double {
        var best = Double.infinity
        for i in 0..<count {
            let dx = xs[i] - x, dz = zs[i] - z
            best = min(best, dx * dx + dz * dz)
        }
        return best.squareRoot()
    }

    /// Punkty kontrolne bez powtórzeń (także ostatni = pierwszy): w splajnie centripetalnym zerowa odległość
    /// między sąsiednimi punktami dzieli przez zero i cała trasa staje się NaN.
    static func withoutRepeats(_ p: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = []
        for q in p where out.last.map({ simd_distance($0, q) > 1e-6 }) ?? true { out.append(q) }
        while out.count > 1, let first = out.first, let last = out.last, simd_distance(first, last) <= 1e-6 { out.removeLast() }
        return out
    }

    /// Zamknięty spline Catmulla-Roma w wersji centripetalnej (bez pętelek na ostrych łukach).
    static func centripetalCatmullRom(_ p: [SIMD2<Double>], samplesPerSegment: Int) -> [SIMD2<Double>] {
        let n = p.count
        var out: [SIMD2<Double>] = []
        for i in 0..<n {
            let p0 = p[(i - 1 + n) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
            let t0 = 0.0
            let t1 = t0 + simd_distance(p0, p1).squareRoot()
            let t2 = t1 + simd_distance(p1, p2).squareRoot()
            let t3 = t2 + simd_distance(p2, p3).squareRoot()
            for k in 0..<samplesPerSegment {
                let t = t1 + (t2 - t1) * Double(k) / Double(samplesPerSegment)
                let a1 = p0 * ((t1 - t) / (t1 - t0)) + p1 * ((t - t0) / (t1 - t0))
                let a2 = p1 * ((t2 - t) / (t2 - t1)) + p2 * ((t - t1) / (t2 - t1))
                let a3 = p2 * ((t3 - t) / (t3 - t2)) + p3 * ((t - t2) / (t3 - t2))
                let b1 = a1 * ((t2 - t) / (t2 - t0)) + a2 * ((t - t0) / (t2 - t0))
                let b2 = a2 * ((t3 - t) / (t3 - t1)) + a3 * ((t - t1) / (t3 - t1))
                out.append(b1 * ((t2 - t) / (t2 - t1)) + b2 * ((t - t1) / (t2 - t1)))
            }
        }
        out.append(out[0])
        return out
    }
}
