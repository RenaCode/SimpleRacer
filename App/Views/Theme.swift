import SwiftUI

enum Theme {
    static let accent = Color(red: 1, green: 0.84, blue: 0.04)
    static let nitro = Color(red: 0.3, green: 0.79, blue: 0.94)
    static let perfect = Color(red: 0.71, green: 0.09, blue: 0.62)
    static let shock = Color(red: 1, green: 0.62, blue: 0.11)
    static let bad = Color(red: 1, green: 0.3, blue: 0.37)
    static let panel = Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.88)

    /// Pochylony, ciężki krój jak w grach wyścigowych.
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .black, design: .default).italic() }
}

/// Pochylony przycisk menu.
struct RaceButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .bold).italic())
            .textCase(.uppercase)
            .tracking(1.2)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .foregroundStyle(primary ? Color.black : Color.white)
            .background(primary ? Theme.accent : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(primary ? 0 : 0.15)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .rotation3DEffect(.degrees(-8), axis: (x: 0, y: 1, z: 0))
    }
}
