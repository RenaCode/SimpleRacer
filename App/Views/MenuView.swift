import RaceCore
import SwiftUI

struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            HStack(spacing: 24) {
                Image("Logo")
                    .resizable()
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: -8) {
                    Text("SIMPLE").foregroundStyle(.white)
                    Text("RACER").foregroundStyle(Theme.accent)
                }
                .font(Theme.display(84))
            }

            Spacer()

            HStack(spacing: 10) {
                Circle().fill(Color(hex: model.profile.colorHex)).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 2))
                Text(model.car.name).textCase(.uppercase).tracking(1.5)
                Text("· moc \(Campaign.rating(model.playerCar))  ★ \(model.campaign.totalStars)  $ \(model.campaign.coins)")
            }
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 10) {
                setting("Auto-prowadzenie", "steeringwheel", $model.profile.autoSteer)
                setting("Muzyka", "music.note", $model.profile.musicOn)
                setting("Dźwięki", "speaker.wave.2.fill", $model.profile.soundOn)
            }
            .frame(width: 300)
            .padding(.bottom, 16)

            HStack(spacing: 14) {
                Button { model.screen = .campaign } label: { Label("Kampania", systemImage: "flag.checkered") }
                    .buttonStyle(RaceButtonStyle(primary: true))
                Button { model.screen = .garage } label: { Label("Garaż", systemImage: "door.garage.closed") }
                    .buttonStyle(RaceButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(48)
    }

    private func setting(_ title: String, _ icon: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Label(title, systemImage: icon).font(.system(size: 17, weight: .bold))
        }
        .toggleStyle(.switch)
        .tint(Theme.accent)
    }
}
