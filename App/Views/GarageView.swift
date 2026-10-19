import RaceCore
import SwiftUI

/// Garaż: tylko wybór auta i koloru lakieru.
struct GarageView: View {
    @Bindable var model: AppModel

    private var customColor: Binding<Color> {
        Binding(
            get: { Color(hex: model.profile.colorHex) },
            set: { model.profile.colorHex = UIColorHex.hex(UIColor($0)) }
        )
    }

    var body: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                Text("Garaż").font(Theme.display(32))

                HStack(spacing: 8) {
                    ForEach(CarCatalog.all) { car in
                        let active = car.id == model.profile.carId
                        Button(car.name) { model.profile.carId = car.id }
                            .font(.system(size: 15, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(active ? Color.black : Color.white)
                            .background(active ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(active ? 0 : 0.15)))
                    }
                }

                Text(model.car.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 40, alignment: .topLeading)

                VStack(spacing: 8) {
                    StatRow(label: "Prędkość", value: model.car.topSpeed, range: CarCatalog.topSpeedRange,
                            text: "\(Int((model.car.topSpeed * 3.6).rounded())) km/h")
                    StatRow(label: "Przyspieszenie", value: model.car.accel, range: CarCatalog.accelRange,
                            text: String(format: "%.0f", model.car.accel))
                    StatRow(label: "Prowadzenie", value: model.car.handling, range: CarCatalog.handlingRange,
                            text: String(format: "%.1f", model.car.handling))
                    StatRow(label: "Nitro", value: model.car.nitroPower, range: CarCatalog.nitroRange,
                            text: String(format: "×%.2f", model.car.nitroPower))
                }

                Text("KOLOR").font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(.secondary).padding(.top, 6)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 10), count: 5), alignment: .leading, spacing: 10) {
                    ForEach(CarCatalog.colors, id: \.self) { hex in
                        Button { model.profile.colorHex = hex } label: {
                            Circle().fill(Color(hex: hex)).frame(width: 40, height: 40)
                                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 2))
                                .overlay(Circle().stroke(Theme.accent, lineWidth: 3).padding(-5)
                                    .opacity(hex == model.profile.colorHex ? 1 : 0))
                        }
                        .accessibilityLabel("Kolor \(hex)")
                    }
                    ColorPicker("Własny kolor", selection: customColor, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 40, height: 40)
                }

                Button { model.screen = .menu } label: { Label("Gotowe", systemImage: "checkmark") }
                    .buttonStyle(RaceButtonStyle(primary: true))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            .padding(24)
            .frame(width: 400)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
        }
        .padding(24)
    }
}

private struct StatRow: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(LinearGradient(colors: [Theme.accent, Theme.shock], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * clamp((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0, 1))
                }
            }
            .frame(height: 6)
            Text(text).fontWeight(.bold).monospacedDigit().frame(width: 76, alignment: .trailing)
        }
        .font(.footnote)
        .animation(.easeOut(duration: 0.3), value: value)
    }
}
