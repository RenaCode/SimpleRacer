import RaceCore
import SwiftUI

/// Ustawienia: sterowanie i dźwięk oraz autorzy i licencje (wymagane przez licencje CC BY).
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = ProcessInfo.processInfo.arguments.contains("-showCredits") ? ["credits"] : []

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section("Gra") {
                    Picker(selection: $model.profile.difficulty) {
                        ForEach(Difficulty.allCases, id: \.self) { Text($0.name).tag($0) }
                    } label: { Label("Poziom trudności", systemImage: "flag.checkered") }
                    Toggle(isOn: $model.profile.autoSteer) { Label("Auto-prowadzenie", systemImage: "steeringwheel") }
                    Toggle(isOn: $model.profile.musicOn) { Label("Muzyka", systemImage: "music.note") }
                    Toggle(isOn: $model.profile.soundOn) { Label("Dźwięki", systemImage: "speaker.wave.2.fill") }
                }
                .tint(Theme.accent)
                Section("O grze") {
                    NavigationLink(value: "credits") { Label("Autorzy i licencje", systemImage: "info.circle") }
                }
            }
            .navigationTitle("Ustawienia")
            .navigationDestination(for: String.self) { _ in CreditsList() }
            .toolbar { Button("Zamknij") { dismiss() } }
        }
    }
}

/// Autorzy muzyki, modeli, zdjęć i tekstur wraz z licencjami.
struct CreditsList: View {
    var body: some View {
        List(LocalAssets.shared.credits) { c in
            VStack(alignment: .leading, spacing: 4) {
                Text(c.title).font(.headline)
                Text(c.author).font(.subheadline)
                Text("Licencja: \(c.license)").font(.footnote).foregroundStyle(.secondary)
                Text(c.source).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Autorzy i licencje")
        .onAppear { debugLog("autorzy: " + LocalAssets.shared.credits.map(\.title).joined(separator: " | ")) }
    }
}
