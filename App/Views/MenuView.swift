import SwiftUI

struct MenuView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: -8) {
                Text("SIMPLE").foregroundStyle(.white)
                Text("RACER").foregroundStyle(Theme.accent)
            }
            .font(Theme.display(84))

            Spacer()

            HStack(spacing: 10) {
                Circle().fill(Color(hex: model.profile.colorHex)).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 2))
                Text(model.car.name).textCase(.uppercase).tracking(1.5)
            }
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 16)

            HStack(spacing: 14) {
                Button { model.startRace() } label: { Label("Wyścig", systemImage: "flag.checkered") }
                    .buttonStyle(RaceButtonStyle(primary: true))
                Button { model.screen = .garage } label: { Label("Garaż", systemImage: "door.garage.closed") }
                    .buttonStyle(RaceButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(48)
    }
}
