import Foundation
import GameController
import RaceCore

/// Sterowanie gracza z trzech źródeł naraz: przyciski dotykowe, klawiatura (Magic Keyboard)
/// i pad. `poll()` odczytuje klawiaturę i pad raz na klatkę; dotyk ustawia widok.
final class GameInput: PlayerInputSource {
    // Dotyk — ustawiane przez TouchControls.
    var touchLeft = false
    var touchRight = false
    var touchDrift = false

    private var nitroQueued = false
    private var deviceSteer = 0.0
    private var deviceDrift = false
    private var prevDeviceNitro = false
    private var prevEscape = false
    private var lastAutoNitroTick = 0

    /// Esc na klawiaturze albo Menu na padzie.
    var onEscape: (() -> Void)?

    var hasKeyboard: Bool { GCKeyboard.coalesced != nil }

    func tapNitro() { nitroQueued = true }

    func poll() {
        var steer = 0.0
        var drift = false
        var nitro = false
        var escape = false

        if let kb = GCKeyboard.coalesced?.keyboardInput {
            let down = { (code: GCKeyCode) in kb.button(forKeyCode: code)?.isPressed ?? false }
            if down(.leftArrow) || down(.keyA) { steer += 1 }
            if down(.rightArrow) || down(.keyD) { steer -= 1 }
            drift = drift || down(.downArrow) || down(.keyS) || down(.leftShift) || down(.rightShift)
            nitro = nitro || down(.spacebar) || down(.upArrow) || down(.keyW)
            escape = escape || down(.escape)
        }
        if let pad = GCController.current?.extendedGamepad {
            let x = Double(pad.leftThumbstick.xAxis.value)
            if abs(x) > 0.15 { steer -= x }
            if pad.dpad.left.isPressed { steer += 1 }
            if pad.dpad.right.isPressed { steer -= 1 }
            drift = drift || pad.buttonB.isPressed || pad.leftTrigger.isPressed
            nitro = nitro || pad.buttonA.isPressed || pad.rightTrigger.isPressed
            escape = escape || pad.buttonMenu.isPressed
        }

        deviceSteer = max(-1, min(1, steer))
        deviceDrift = drift
        if nitro && !prevDeviceNitro { nitroQueued = true }
        #if DEBUG || FAMILY
        // `-autoNitro`: co 4 s wciska nitro (pokaz efektów w symulatorze).
        if ProcessInfo.processInfo.arguments.contains("-autoNitro") {
            let tick = Int(ProcessInfo.processInfo.systemUptime / 4)
            if tick != lastAutoNitroTick { lastAutoNitroTick = tick; nitroQueued = true }
        }
        #endif
        prevDeviceNitro = nitro
        if escape && !prevEscape { onEscape?() }
        prevEscape = escape
    }

    var steer: Double {
        var s = deviceSteer
        if touchLeft { s += 1 }
        if touchRight { s -= 1 }
        return max(-1, min(1, s))
    }

    var drift: Bool { deviceDrift || touchDrift || debugHoldDrift }

    #if DEBUG || FAMILY
    /// Do zrzutów w symulatorze: `-holdDrift` trzyma DRIFT wciśnięty od 8. sekundy po starcie aplikacji (po rozpędzeniu).
    private let debugDriftFrom: Double? = ProcessInfo.processInfo.arguments.contains("-holdDrift")
        ? ProcessInfo.processInfo.systemUptime + 8 : nil
    private var debugHoldDrift: Bool { debugDriftFrom.map { ProcessInfo.processInfo.systemUptime > $0 } ?? false }
    #else
    private let debugHoldDrift = false
    #endif

    func consumeNitro() -> Bool {
        defer { nitroQueued = false }
        return nitroQueued
    }
}
