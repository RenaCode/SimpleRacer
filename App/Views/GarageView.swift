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

    /// Auto oglądane w garażu i jego statystyki z ulepszeniami.
    private var shown: CarDef { model.previewCar }
    private var stats: CarDef { Campaign.upgraded(shown, in: model.campaign) }
    private var owned: Bool { Campaign.owns(shown.id, model.campaign) }

    /// Warsztat: ulepszenia własnego auta albo zakup cudzego.
    @ViewBuilder private var workshop: some View {
        HStack {
            Text("MOC \(Campaign.rating(stats))").font(Theme.display(22)).foregroundStyle(Theme.nitro)
            Spacer()
            if !owned {
                let price = Campaign.price(of: shown)
                Button {
                    try? Campaign.buyCar(shown, &model.campaign)
                    if Campaign.owns(shown.id, model.campaign) { model.profile.carId = shown.id }
                } label: { Label("Kup za \(price)", systemImage: "cart.fill") }
                    .buttonStyle(RaceButtonStyle(primary: true))
                    .disabled(model.campaign.coins < price)
            }
        }
        if owned {
            VStack(spacing: 6) {
                ForEach(Upgrade.allCases, id: \.self) { u in
                    let level = model.campaign.level(u, car: shown.id)
                    HStack(spacing: 8) {
                        Text(u.name).font(.footnote.weight(.semibold)).frame(width: 110, alignment: .leading)
                        HStack(spacing: 3) {
                            ForEach(0..<Campaign.maxLevel, id: \.self) { i in
                                Capsule().fill(i < level ? Theme.accent : Color.white.opacity(0.15)).frame(width: 18, height: 7)
                            }
                        }
                        Spacer()
                        if level < Campaign.maxLevel {
                            let cost = Campaign.upgradeCost(toLevel: level + 1)
                            Button { try? Campaign.buyUpgrade(u, car: shown.id, &model.campaign) } label: {
                                Label("\(cost)", systemImage: "plus.circle.fill").font(.footnote.weight(.bold))
                            }
                            .disabled(model.campaign.coins < cost)
                            .accessibilityIdentifier("ulepsz.\(u.rawValue)")
                        } else {
                            Text("MAX").font(.caption.weight(.heavy)).foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
    }

    /// Wszystkie auta naraz, po trzy w rzędzie; gdy przybędzie aut ponad wysokość panelu — przewijanie.
    private var carGrid: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(CarCatalog.all) { car in carTile(car) }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func carTile(_ car: CarDef) -> some View {
        let active = car.id == model.previewCar.id
        let owned = Campaign.owns(car.id, model.campaign)
        return Button {
            model.garageCarId = car.id
            if owned { model.profile.carId = car.id }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(car.name).font(.system(size: 13, weight: .bold)).lineLimit(2).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                HStack(spacing: 3) {
                    if owned {
                        Text("moc \(Campaign.rating(Campaign.upgraded(car, in: model.campaign)))")
                    } else {
                        Image(systemName: "lock.fill")
                        Text("\(Campaign.price(of: car))")
                    }
                }
                .font(.caption2.weight(.semibold))
                .opacity(0.8)
            }
            .padding(8)
            .foregroundStyle(active ? Color.black : Color.white)
            .background(active ? Theme.accent : Color.white.opacity(owned ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(active ? 0 : 0.15)))
        }
    }

    private var colors: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 10), count: 5), alignment: .leading, spacing: 10) {
            ForEach(CarCatalog.colors, id: \.self) { hex in
                Button { model.profile.colorHex = hex } label: {
                    Circle().fill(Color(hex: hex)).frame(width: 36, height: 36)
                        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 2))
                        .overlay(Circle().stroke(Theme.accent, lineWidth: 3).padding(-4)
                            .opacity(hex == model.profile.colorHex ? 1 : 0))
                }
                .accessibilityLabel("Kolor \(hex)")
            }
            ColorPicker("Własny kolor", selection: customColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 36, height: 36)
        }
    }

    var body: some View {
        HStack {
            Spacer()
            // Dwie kolumny: auta po lewej, moc/ulepszenia/kolory po prawej — wszystko mieści się bez przewijania.
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Garaż").font(Theme.display(32))
                        Spacer()
                        StatPill(icon: "dollarsign.circle.fill", text: "\(model.campaign.coins)", color: Theme.shock)
                    }
                    carGrid
                    Text(shown.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                }
                .frame(width: 300)

                VStack(alignment: .leading, spacing: 12) {
                    workshop
                    VStack(spacing: 7) {
                        StatRow(label: "Prędkość", value: stats.topSpeed, range: CarCatalog.topSpeedRange,
                                text: "\(Int((stats.topSpeed * 3.6).rounded())) km/h")
                        StatRow(label: "Przyspieszenie", value: stats.accel, range: CarCatalog.accelRange,
                                text: String(format: "%.0f", stats.accel))
                        StatRow(label: "Prowadzenie", value: stats.handling, range: CarCatalog.handlingRange,
                                text: String(format: "%.1f", stats.handling))
                        StatRow(label: "Nitro", value: stats.nitroPower, range: CarCatalog.nitroRange,
                                text: String(format: "×%.2f", stats.nitroPower))
                    }
                    Text("KOLOR").font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(.secondary)
                    // Auta z bajki (lakier w teksturze z napisami i rdzą): kolor nic by nie zmienił.
                    if let r = shown.realistic, r.paintParts.isEmpty {
                        Text("Oryginalne malowanie").font(.callout).foregroundStyle(.secondary)
                    } else {
                        colors
                    }
                    Spacer(minLength: 0)
                    Button {
                        model.garageCarId = nil
                        model.screen = .menu
                    } label: { Label("Gotowe", systemImage: "checkmark") }
                        .buttonStyle(RaceButtonStyle(primary: true))
                        .frame(maxWidth: .infinity)
                }
                .frame(width: 310)
            }
            .padding(22)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
        }
        .padding(20)
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
