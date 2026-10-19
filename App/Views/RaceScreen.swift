import RaceCore
import RealityKit
import SwiftUI

struct RaceScreen: View {
    let model: AppModel
    @State private var game: RaceGame

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
            }
            if let r = game.result {
                ResultsView(result: r,
                            again: { model.startRace() },
                            garage: { model.screen = .garage },
                            menu: { model.screen = .menu })
            }
        }
        .onAppear { game.input.onEscape = { model.screen = .menu } }
        .onDisappear { game.subscription?.cancel() }
    }
}
