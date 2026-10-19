import SwiftUI

struct ResultsView: View {
    let result: RaceResult
    let next: (() -> Void)?
    let again: () -> Void
    let garage: () -> Void
    let campaign: () -> Void

    private var placeColor: Color {
        switch result.position {
        case 1: Theme.accent
        case 2: Color(white: 0.86)
        case 3: Color(red: 0.88, green: 0.62, blue: 0.35)
        default: .white
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 16) {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("\(result.position)").font(Theme.display(84)).foregroundStyle(placeColor)
                    Text("/\(result.total)").font(Theme.display(28)).foregroundStyle(.secondary)
                }
                Text(result.position == 1 ? "Zwycięstwo!" : "Meta").font(Theme.display(32))
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Image(systemName: i < result.stars ? "star.fill" : "star")
                            .font(.system(size: 34))
                            .foregroundStyle(i < result.stars ? Theme.accent : .white.opacity(0.3))
                    }
                }
                HStack(spacing: 16) {
                    Label("+\(result.coins)", systemImage: "dollarsign.circle.fill").foregroundStyle(Theme.shock)
                    if result.newBest { Label("Nowy rekord!", systemImage: "sparkles").foregroundStyle(Theme.accent) }
                }
                .font(.title3.weight(.bold))
                Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 8) {
                    row("Czas", formatTime(result.time))
                    row("Takedowny", "\(result.takedowns)")
                    row("Auto", result.carName)
                }
                HStack(spacing: 12) {
                    if let next {
                        Button(action: next) { Label("Dalej", systemImage: "arrow.right") }
                            .buttonStyle(RaceButtonStyle(primary: true))
                    }
                    Button(action: again) { Label("Jeszcze raz", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(RaceButtonStyle(primary: next == nil))
                    Button(action: garage) { Label("Garaż", systemImage: "door.garage.closed") }
                        .buttonStyle(RaceButtonStyle())
                    Button(action: campaign) { Label("Kampania", systemImage: "map.fill") }
                        .buttonStyle(RaceButtonStyle())
                }
                .padding(.top, 8)
            }
            .padding(32)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.bold).monospacedDigit().gridColumnAlignment(.trailing)
        }
    }
}
