public enum NitroMode: Sendable {
    case off, normal, perfect, shockwave
}

/// Nitro:
/// - jedno wciśnięcie — zwykłe nitro na `burnTime` sekund,
/// - ponowne wciśnięcie pod koniec spalania (okno `perfectWindow`) — perfect nitro, mocniejsze,
/// - dwa szybkie wciśnięcia — fala uderzeniowa: spala cały pasek, najmocniejszy zryw.
/// Pasek ładuje się driftem, mijaniem „na włos” i rozbijaniem rywali.
public final class Nitro {
    public var gauge = NitroConfig.startGauge
    public private(set) var mode: NitroMode = .off
    public private(set) var burnLeft = 0.0
    private var drain = 0.0
    private var sinceTap = Double.infinity
    private var lastTapActivated = false

    public init() {}

    public func add(_ amount: Double) { gauge = min(1, gauge + amount) }

    public var inPerfectWindow: Bool {
        (mode == .normal || mode == .perfect) && burnLeft <= NitroConfig.perfectWindow
    }

    public var boost: Double { NitroConfig.boost(mode) }

    public func cancel() {
        mode = .off
        burnLeft = 0
    }

    /// Zwraca tryb, który właśnie się włączył, albo nil.
    @discardableResult
    public func update(dt: Double, pressed: Bool) -> NitroMode? {
        sinceTap += dt
        var started: NitroMode?

        if pressed {
            let doubleTap = sinceTap <= NitroConfig.doubleTapWindow && lastTapActivated
            sinceTap = 0
            lastTapActivated = false

            if doubleTap && mode == .normal && gauge >= NitroConfig.shockwaveMinGauge {
                mode = .shockwave
                burnLeft = NitroConfig.shockwaveTime
                drain = gauge / NitroConfig.shockwaveTime
                started = .shockwave
            } else if mode == .off && gauge >= NitroConfig.minToActivate {
                mode = .normal
                burnLeft = NitroConfig.burnTime
                drain = NitroConfig.drainPerSec
                lastTapActivated = true
                started = .normal
            } else if inPerfectWindow && gauge > 0 {
                mode = .perfect
                burnLeft = NitroConfig.burnTime
                drain = NitroConfig.drainPerSec
                started = .perfect
            }
        }

        if mode != .off {
            burnLeft -= dt
            gauge = max(0, gauge - drain * dt)
            if gauge <= 0 || burnLeft <= 0 { cancel() }
        }
        return started
    }
}
