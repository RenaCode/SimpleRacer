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

/// Równoległobok: lewa krawędź pochylona (`slant` pt u góry wsunięte), prawa prosta — jak przyciski z makiet.
/// `trailing` pochyla prawą krawędź zamiast lewej (np. baner z logo przy lewym brzegu ekranu).
struct SlantShape: Shape {
    var slant: CGFloat = 24
    var trailing = false

    func path(in r: CGRect) -> Path {
        var p = Path()
        if trailing {
            p.addLines([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                        CGPoint(x: r.maxX - slant, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
        } else {
            p.addLines([CGPoint(x: r.minX + slant, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                        CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
        }
        p.closeSubpath()
        return p
    }
}

/// Duży pochylony przycisk z piktogramem w kole — dziecko rozpoznaje ikonę, rodzic czyta napis.
/// Żółty = główna akcja (ciemne koło), ciemny = pozostałe (jasne koło).
struct PictoButton: View {
    let title: String
    let icon: String
    var primary = false
    var height: CGFloat = 92
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                let badge = height * (primary ? 0.74 : 0.68)
                ZStack {
                    Circle().fill(primary ? Color(white: 0.07) : Color.white.opacity(0.1))
                    Circle().stroke(primary ? Color(white: 0.07) : Color.white.opacity(0.25), lineWidth: 3)
                    Image(systemName: icon)
                        .font(.system(size: badge * 0.48, weight: .bold))
                        .foregroundStyle(primary ? Theme.accent : Color.white)
                }
                .frame(width: badge, height: badge)
                Text(title)
                    .font(Theme.display(height * 0.31))
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(primary ? Color(white: 0.07) : Color.white)
                Spacer(minLength: 0)
            }
            .padding(.leading, 38)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(
                SlantShape().fill(LinearGradient(
                    colors: primary ? [Theme.accent, Color(red: 1, green: 0.76, blue: 0)]
                                    : [Color(red: 0.08, green: 0.09, blue: 0.11), Color(red: 0.12, green: 0.13, blue: 0.15)],
                    startPoint: .leading, endPoint: .trailing))
            )
            .contentShape(SlantShape())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(title)
    }
}

/// Lekkie wciśnięcie przycisku.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1, anchor: .trailing)
            .brightness(configuration.isPressed ? -0.06 : 0)
    }
}
