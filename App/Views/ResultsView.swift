import SwiftUI

struct ResultsView: View {
    let result: RaceResult
    let again: () -> Void
    let garage: () -> Void
    let menu: () -> Void

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
                Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 8) {
                    row("Czas", formatTime(result.time))
                    row("Takedowny", "\(result.takedowns)")
                    row("Auto", result.carName)
                }
                HStack(spacing: 12) {
                    Button(action: again) { Label("Jeszcze raz", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(RaceButtonStyle(primary: true))
                    Button(action: garage) { Label("Garaż", systemImage: "door.garage.closed") }
                        .buttonStyle(RaceButtonStyle())
                    Button(action: menu) { Label("Menu", systemImage: "house.fill") }
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
