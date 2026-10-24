import SwiftUI

/// Przyciski dotykowe: lewa strona — skręt, prawa — drift i nitro (dwa szybkie tapnięcia = fala).
struct TouchControls: View {
    let input: GameInput

    var body: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                SteerPad(input: input)
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

/// Skręt: jeden gest na oba przyciski, kierunek z położenia palca. Osobne przyciski trzymały pierwszy wciśnięty,
/// dopóki palec nie oderwał się od ekranu — przesunięcie z ◀ na ▶ nie zmieniało kierunku.
private struct SteerPad: View {
    let input: GameInput
    private let size: CGFloat = 96
    private let spacing: CGFloat = 18
    /// -1 w lewo, 1 w prawo, 0 puszczone; `@GestureState` zeruje się sam także przy przerwanym geście.
    @GestureState private var side = 0

    var body: some View {
        HStack(spacing: spacing) {
            RoundKey(label: "◀", size: size, pressed: side == -1)
                .accessibilityElement()
                .accessibilityLabel("W lewo")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { pulse { input.touchLeft = $0 } }
            RoundKey(label: "▶", size: size, pressed: side == 1)
                .accessibilityElement()
                .accessibilityLabel("W prawo")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { pulse { input.touchRight = $0 } }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).updating($side) { v, state, _ in
            state = v.location.x < size + spacing / 2 ? -1 : 1
        })
        .onChange(of: side) { _, now in
            input.touchLeft = now == -1
            input.touchRight = now == 1
        }
    }
}

/// VoiceOver: „stuknięcie” w przycisk przytrzymania — krótkie wciśnięcie i puszczenie.
@MainActor
private func pulse(_ set: @escaping (Bool) -> Void) {
    set(true)
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(400))
        set(false)
    }
}

/// Okrągły przycisk z napisem; podświetlony, gdy wciśnięty.
private struct RoundKey: View {
    let label: String
    let size: CGFloat
    var tint: Color = .white
    let pressed: Bool

    var body: some View {
        Text(label)
            .font(Theme.display(label.count > 1 ? 16 : 30))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(pressed ? Color.white.opacity(0.3) : Color.black.opacity(0.3)))
            .overlay(Circle().stroke(tint.opacity(0.6), lineWidth: 2))
            .contentShape(Circle())
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
        RoundKey(label: label, size: size, tint: tint, pressed: pressed)
            .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, state, _ in state = true })
            .onChange(of: pressed) { _, now in onChange(now) }
            .accessibilityElement()
            .accessibilityLabel(name)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { pulse(onChange) }
    }
}
