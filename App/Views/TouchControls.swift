import SwiftUI

/// Przyciski dotykowe: lewa strona — skręt, prawa — drift i nitro (dwa szybkie tapnięcia = fala).
struct TouchControls: View {
    let input: GameInput

    var body: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                HStack(spacing: 18) {
                    HoldButton(label: "◀", name: "W lewo", size: 96) { input.touchLeft = $0 }
                    HoldButton(label: "▶", name: "W prawo", size: 96) { input.touchRight = $0 }
                }
                Spacer()
                HStack(spacing: 18) {
                    HoldButton(label: "DRIFT", name: "Drift", size: 96) { input.touchDrift = $0 }
                    HoldButton(label: "NITRO", name: "Nitro", size: 110, tint: Theme.nitro) { pressed in
                        if pressed { input.tapNitro() }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }
}

/// Przycisk reagujący na dotknięcie i puszczenie (nie na „kliknięcie”), działa wielodotykowo.
/// Stan wciśnięcia trzyma `@GestureState`, który SwiftUI zeruje sam także przy przerwanym geście
/// (np. gest systemowy) — przycisk nie może zostać „wciśnięty” na stałe.
private struct HoldButton: View {
    let label: String
    /// Nazwa dla VoiceOver i testów UI.
    let name: String
    let size: CGFloat
    var tint: Color = .white
    let onChange: (Bool) -> Void
    @GestureState private var pressed = false

    var body: some View {
        Text(label)
            .font(Theme.display(label.count > 1 ? 16 : 30))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(pressed ? Color.white.opacity(0.3) : Color.black.opacity(0.3)))
            .overlay(Circle().stroke(tint.opacity(0.6), lineWidth: 2))
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, state, _ in state = true })
            .onChange(of: pressed) { _, now in onChange(now) }
            .accessibilityElement()
            .accessibilityLabel(name)
            .accessibilityAddTraits(.isButton)
    }
}
