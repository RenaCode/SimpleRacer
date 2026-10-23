import RaceCore
import SwiftUI

/// Menu główne (makieta „menu” z piktogramami): baner z logo, monety i gwiazdki, auto na podeście,
/// po prawej kolumna dużych przycisków, na dole przełącznik auto-prowadzenia.
struct MenuView: View {
    @Bindable var model: AppModel
    #if DEBUG || FAMILY
    /// `-showCredits` otwiera ustawienia na liście autorów (sprawdzanie licencji w symulatorze).
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-showCredits")
    #else
    @State private var showSettings = false
    #endif

    var body: some View {
        GeometryReader { geo in
            let columnWidth = min(420, geo.size.width * 0.36)
            ZStack {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        LogoBanner()
                        Spacer()
                        HStack(spacing: 12) {
                            MenuPill(icon: "dollarsign.circle.fill", color: Theme.shock, text: model.campaign.coins.formatted())
                            MenuPill(icon: "star.fill", color: Theme.accent, text: "\(model.campaign.totalStars)")
                        }
                        .padding(.trailing, 36)
                    }
                    .padding(.top, 34)
                    Spacer()
                    AutoSteerPill(isOn: $model.profile.autoSteer)
                        .padding(.leading, 32)
                        .padding(.bottom, 28)
                }

                VStack(spacing: 14) {
                    PictoButton(title: "Ścigaj się", icon: "play.fill", primary: true, height: 100) {
                        model.startRace(track: Campaign.nextTrack(model.campaign, car: model.car).id)
                    }
                    PictoButton(title: "Kampania", icon: "map.fill") { model.screen = .campaign }
                    PictoButton(title: "Garaż", icon: "car.fill") { model.screen = .garage }
                    PictoButton(title: "Ustawienia", icon: "gearshape.fill") { showSettings = true }
                }
                .frame(width: columnWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .offset(y: geo.size.height * 0.06)
            }
        }
        .ignoresSafeArea(edges: [.trailing, .leading])
        .sheet(isPresented: $showSettings) { SettingsView(model: model) }
    }
}

/// Żółty baner z logo przy lewej krawędzi ekranu, z liniami pędu.
struct LogoBanner: View {
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .trailing, spacing: 7) {
                ForEach([46, 64, 38, 56], id: \.self) { w in
                    Capsule().fill(Color(white: 0.07)).frame(width: CGFloat(w), height: 7)
                }
            }
            VStack(alignment: .leading, spacing: -12) {
                Text("SIMPLE")
                Text("RACER")
            }
            .font(Theme.display(62))
            .foregroundStyle(Color(white: 0.07))
        }
        .padding(.leading, 44)
        .padding(.trailing, 64)
        .padding(.vertical, 14)
        .background(SlantShape(slant: 34, trailing: true).fill(Theme.accent))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Simple Racer")
    }
}

private struct MenuPill: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 24, weight: .bold))
            Text(text).font(.system(size: 22, weight: .heavy)).monospacedDigit().foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Color(white: 0.06).opacity(0.75), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15)))
    }
}

/// Przełącznik auto-prowadzenia jak na makiecie: kapsuła ON/OFF z gałką i podpis.
private struct AutoSteerPill: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(.snappy(duration: 0.2)) { isOn.toggle() } } label: {
            HStack(spacing: 14) {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Theme.nitro.opacity(0.9) : Color.white.opacity(0.18))
                    Text(isOn ? "ON" : "OFF")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(isOn ? Color(white: 0.07) : .white)
                        .frame(maxWidth: .infinity, alignment: isOn ? .leading : .trailing)
                        .padding(.horizontal, 10)
                    Circle().fill(.white).padding(4)
                }
                .frame(width: 78, height: 38)
                Image(systemName: "steeringwheel").font(.system(size: 20, weight: .bold))
                Text("Auto-prowadzenie").font(.system(size: 19, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.leading, 8).padding(.trailing, 20).padding(.vertical, 7)
            .background(Color(white: 0.06).opacity(0.8), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.15)))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Auto-prowadzenie")
        .accessibilityValue(isOn ? "ON" : "OFF")
        .accessibilityValue(isOn ? "włączone" : "wyłączone")
    }
}
