import RaceCore
import SwiftUI

/// Kampania: 5 krain po 8 tras. Na kartach gwiazdki, wymagana moc i kłódki.
struct CampaignView: View {
    @Bindable var model: AppModel
    @State private var region: Region = .city
    @State private var tooWeak: TrackSpec?

    private var rating: Int { Campaign.rating(model.playerCar) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button { model.screen = .menu } label: { Label("Menu", systemImage: "chevron.left") }
                    .buttonStyle(RaceButtonStyle())
                Spacer()
                StatPill(icon: "star.fill", text: "\(model.campaign.totalStars)", color: Theme.accent)
                StatPill(icon: "dollarsign.circle.fill", text: "\(model.campaign.coins)", color: Theme.shock)
                StatPill(icon: "bolt.car.fill", text: "\(model.car.name) · moc \(rating)", color: Theme.nitro)
                Button { model.screen = .garage } label: { Label("Garaż", systemImage: "door.garage.closed") }
                    .buttonStyle(RaceButtonStyle())
            }

            HStack(spacing: 10) {
                ForEach(Region.allCases, id: \.self) { r in
                    let open = Campaign.isRegionUnlocked(r, model.campaign)
                    Button { region = r } label: {
                        HStack(spacing: 6) {
                            if !open { Image(systemName: "lock.fill") }
                            Text(r.name)
                        }
                        .font(.system(size: 17, weight: .bold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .foregroundStyle(region == r ? Color.black : .white)
                        .background(region == r ? Theme.accent : Color.white.opacity(0.08), in: Capsule())
                    }
                }
            }

            if !Campaign.isRegionUnlocked(region, model.campaign) {
                Label("Zbierz \(Campaign.starsToUnlock[region.rawValue]) gwiazdek, żeby wjechać do krainy \(region.name).",
                      systemImage: "star.circle")
                    .font(.headline).foregroundStyle(.secondary)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                ForEach(TrackCatalog.all.filter { $0.region == region }) { spec in
                    TrackCard(spec: spec, state: model.campaign, rating: rating) {
                        if Campaign.canRace(model.car, on: spec, model.campaign) {
                            model.startRace(track: spec.id)
                        } else {
                            tooWeak = spec
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(28)
        .background(LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.12), Color(red: 0.12, green: 0.08, blue: 0.24)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
        .onAppear { region = TrackCatalog.track(id: model.trackId).region }
        .alert("Za słabe auto", isPresented: Binding(get: { tooWeak != nil }, set: { if !$0 { tooWeak = nil } })) {
            Button("Do garażu") { model.screen = .garage }
            Button("Zamknij", role: .cancel) {}
        } message: {
            if let t = tooWeak {
                Text("Na trasę „\(t.name)” potrzeba mocy \(Campaign.requiredRating(t)), a Twoje auto ma \(rating). Ulepsz auto w garażu albo kup mocniejsze.")
            }
        }
    }
}

private struct TrackCard: View {
    let spec: TrackSpec
    let state: CampaignState
    let rating: Int
    let action: () -> Void

    var body: some View {
        let open = Campaign.isUnlocked(spec, state)
        let stars = state.bestStars[spec.id] ?? 0
        let need = Campaign.requiredRating(spec)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(spec.id)").font(Theme.display(30))
                    Spacer()
                    if !open { Image(systemName: "lock.fill").font(.title2) }
                }
                Text(spec.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { i in
                        Image(systemName: i < stars ? "star.fill" : "star")
                            .foregroundStyle(i < stars ? Theme.accent : .white.opacity(0.3))
                    }
                }
                Label("moc \(need)", systemImage: "bolt.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(rating >= need ? Theme.nitro : Theme.bad)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .background(Color.white.opacity(open ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(stars == 3 ? Theme.accent : .white.opacity(0.12), lineWidth: stars == 3 ? 2 : 1))
            .opacity(open ? 1 : 0.5)
        }
        .disabled(!open)
    }
}

struct StatPill: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 16, weight: .bold))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color.white.opacity(0.08), in: Capsule())
            .foregroundStyle(color)
    }
}
