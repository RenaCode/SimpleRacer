import RaceCore
import RealityKit
import SwiftUI

struct RaceScreen: View {
    let model: AppModel
    @State private var game: RaceGame
    @Environment(\.scenePhase) private var scenePhase

    init(model: AppModel) {
        self.model = model
        _game = State(initialValue: RaceGame(profile: model.profile))
    }

    var body: some View {
        ZStack {
            RealityView { content in
                content.camera = .virtual
                content.add(game.root)
                let game = self.game
                // Słaba referencja: gra trzyma subskrypcję, więc mocna dawałaby cykl i wyciek całej sceny po każdym wyścigu.
                game.subscription = content.subscribe(to: SceneEvents.Update.self) { [weak game] event in
                    MainActor.assumeIsolated { game?.update(dt: event.deltaTime) }
                }
            }
            .ignoresSafeArea()

            HudView(game: game)
                .opacity(game.result == nil ? 1 : 0.25)
            if game.result == nil {
                TouchControls(input: game.input)
                PauseButton { game.paused = true }
            }
            if game.paused && game.result == nil {
                PauseView(resume: { game.paused = false },
                          restart: { model.startRace() },
                          menu: { model.screen = .menu })
            }
            if let r = game.result {
                ResultsView(result: r,
                            again: { model.startRace() },
                            garage: { model.screen = .garage },
                            menu: { model.screen = .menu })
            }
        }
        .onAppear { game.input.onEscape = { [weak game] in game?.paused.toggle() } }
        // Wyjście z aplikacji, powiadomienie albo centrum sterowania — gra staje i czeka.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && game.result == nil { game.paused = true }
        }
        .onDisappear {
            game.subscription?.cancel()
            AudioManager.shared.setEngine(speed: 0, nitro: false, running: false)
        }
    }
}

/// Przycisk pauzy u góry ekranu, obok pozycji.
private struct PauseButton: View {
    let action: () -> Void

    var body: some View {
        VStack {
            Button(action: action) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.black.opacity(0.35)))
                    .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 2))
            }
            .accessibilityLabel("Pauza")
            .padding(.top, 14)
            Spacer()
        }
    }
}

private struct PauseView: View {
    let resume: () -> Void
    let restart: () -> Void
    let menu: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("Pauza").font(Theme.display(44))
                Button(action: resume) { Label("Graj dalej", systemImage: "play.fill") }
                    .buttonStyle(RaceButtonStyle(primary: true))
                HStack(spacing: 12) {
                    Button(action: restart) { Label("Od nowa", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(RaceButtonStyle())
                    Button(action: menu) { Label("Menu", systemImage: "house.fill") }
                        .buttonStyle(RaceButtonStyle())
                }
            }
            .padding(32)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
        }
    }
}
