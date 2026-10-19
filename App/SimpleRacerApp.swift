import SwiftUI

@main
struct SimpleRacerApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
        // Dźwięk tylko, gdy gra jest na ekranie.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { AudioManager.shared.start() } else { AudioManager.shared.stop() }
        }
    }
}
