import Foundation

@inlinable public func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(hi, max(lo, v)) }

@inlinable public func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

/// Wygładzanie niezależne od liczby klatek: zbliża `current` do `target` z szybkością `rate` 1/s.
@inlinable public func damp(_ current: Double, _ target: Double, rate: Double, dt: Double) -> Double {
    target + (current - target) * exp(-rate * dt)
}

/// Pozycja na pętli długości `len`, zawsze w [0, len).
@inlinable public func wrap(_ v: Double, _ len: Double) -> Double {
    let r = v.truncatingRemainder(dividingBy: len)
    let w = r < 0 ? r + len : r
    return w >= len ? 0 : w
}

/// Najkrótsza różnica a − b na pętli długości `len`, w [−len/2, len/2).
@inlinable public func wrapDelta(_ a: Double, _ b: Double, _ len: Double) -> Double {
    wrap(a - b + len / 2, len) - len / 2
}

@inlinable public func wrapAngle(_ a: Double) -> Double { wrapDelta(a, 0, 2 * .pi) }

@inlinable public func dampAngle(_ current: Double, _ target: Double, rate: Double, dt: Double) -> Double {
    current + wrapAngle(target - current) * (1 - exp(-rate * dt))
}

/// Deterministyczny generator (SplitMix64) — ta sama trasa i rywale przy tym samym ziarnie.
public final class SeededRandom {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    /// Liczba z [0, 1).
    public func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    public func pick<T>(_ items: [T]) -> T { items[min(items.count - 1, Int(next() * Double(items.count)))] }
}
