import CoreHaptics
import GameController

/// Wibracje pada (iPady nie mają silnika haptycznego, więc tylko kontroler z wibracjami, np. DualSense
/// czy Xbox). Krótkie impulsy przy uderzeniu w bandę, rozbiciu, takedownie i odpaleniu nitro. Bez pada
/// albo bez wibracji w padzie — nic się nie dzieje.
@MainActor
final class Haptics {
    static let shared = Haptics()

    private var engine: CHHapticEngine?
    private weak var engineController: GCController?

    private init() {}

    /// `intensity` i `sharpness` 0…1, `duration` w sekundach (krótszy niż ~0,1 s — pojedyncze stuknięcie).
    func pulse(intensity: Float, sharpness: Float = 0.5, duration: Double = 0.08) {
        guard let engine = currentEngine() else { return }
        let params = [CHHapticEventParameter(parameterID: .hapticIntensity, value: min(1, max(0, intensity))),
                      CHHapticEventParameter(parameterID: .hapticSharpness, value: min(1, max(0, sharpness)))]
        let event = duration < 0.1
            ? CHHapticEvent(eventType: .hapticTransient, parameters: params, relativeTime: 0)
            : CHHapticEvent(eventType: .hapticContinuous, parameters: params, relativeTime: 0, duration: duration)
        do {
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Silnik pada potrafi się zatrzymać (uśpienie, rozłączenie) — następnym razem tworzymy nowy.
            self.engine = nil
        }
    }

    private func currentEngine() -> CHHapticEngine? {
        guard let controller = GCController.current, let haptics = controller.haptics else { return nil }
        if let engine, engineController === controller { return engine }
        guard let e = haptics.createEngine(withLocality: .default) else { return nil }
        e.isAutoShutdownEnabled = true
        e.resetHandler = { [weak e] in try? e?.start() }
        try? e.start()
        engine = e
        engineController = controller
        return e
    }
}
