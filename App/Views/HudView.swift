import RaceCore
import SwiftUI

struct HudView: View {
    let game: RaceGame

    var body: some View {
        let h = game.hud
        ZStack {
            VStack {
                HStack(alignment: .top) {
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text("\(h.position)").font(Theme.display(56))
                        Text("/\(h.total)").font(Theme.display(22)).opacity(0.8)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("OKR. \(h.lap)/\(h.laps)").font(Theme.display(22))
                        Text(formatTime(h.time)).font(.system(size: 16, weight: .bold)).monospacedDigit().opacity(0.85)
                    }
                }
                Spacer()
                VStack(spacing: 6) {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(Int(h.speedKmh.rounded()))").font(Theme.display(54)).monospacedDigit()
                        Text("km/h").font(Theme.display(16)).opacity(0.8)
                    }
                    NitroBar(hud: h)
                }
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            if let c = game.countdownText {
                Text(c).font(Theme.display(160)).foregroundStyle(Theme.accent)
                    .transition(.scale.combined(with: .opacity))
                    .id(c)
            }

            VStack(spacing: 4) {
                ForEach(game.toasts) { t in
                    Text(t.text)
                        .font(Theme.display(34))
                        .foregroundStyle(t.kind == .good ? Theme.accent : t.kind == .bad ? Theme.bad : Theme.nitro)
                        .transition(.asymmetric(insertion: .scale(scale: 1.6).combined(with: .opacity), removal: .opacity))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 140)
            .animation(.spring(duration: 0.25), value: game.toasts)

            if game.input.hasKeyboard {
                Text("←/→ skręt · ↓ drift/hamulec · spacja nitro (2× fala) · Esc menu")
                    .font(.footnote.weight(.medium)).opacity(0.7)
                    // U góry, bo na dole leżą przyciski dotykowe.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 24)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
        .allowsHitTesting(false)
    }
}

private struct NitroBar: View {
    let hud: HudState

    private var fill: [Color] {
        switch hud.mode {
        case .perfect: [Color(red: 0.45, green: 0.04, blue: 0.72), Theme.perfect]
        case .shockwave: [Color(red: 0.95, green: 0.45, blue: 0.17), Theme.shock]
        default: [Color(red: 0.12, green: 0.47, blue: 0.71), Theme.nitro]
        }
    }

    private var label: String {
        if hud.perfectWindow { return "TERAZ!" }
        switch hud.mode {
        case .shockwave: return "FALA"
        case .perfect: return "PERFECT"
        default: return "NITRO"
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    Capsule().fill(.black.opacity(0.5))
                    Capsule().fill(LinearGradient(colors: fill, startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * hud.gauge)
                    Rectangle().fill(.white).frame(width: geo.size.width * hud.burn, height: 3)
                }
                .clipShape(Capsule())
                .overlay(Capsule().stroke(hud.perfectWindow ? Theme.perfect : .white.opacity(0.25), lineWidth: hud.perfectWindow ? 2 : 1))
                .shadow(color: hud.perfectWindow ? Theme.perfect : (hud.mode == .off && hud.gauge >= NitroConfig.minToActivate ? Theme.nitro : .clear), radius: 8)
            }
            .frame(width: 300, height: 14)
            Text(label).font(Theme.display(15)).foregroundStyle(hud.perfectWindow ? Theme.perfect : .white)
        }
    }
}

func formatTime(_ t: Double) -> String {
    let m = Int(t / 60)
    return String(format: "%d:%05.2f", m, t - Double(m * 60))
}
