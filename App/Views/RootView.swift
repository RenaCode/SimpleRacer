import RealityKit
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var preview = GaragePreview()

    var body: some View {
        ZStack {
            switch model.screen {
            case .menu, .garage:
                GeometryReader { geo in
                    PreviewStage(preview: preview, model: model, narrow: geo.size.width < 760)
                }
                .ignoresSafeArea()
                if model.screen == .menu {
                    MenuView(model: model)
                } else {
                    GarageView(model: model)
                }
            case .campaign:
                CampaignView(model: model)
            case let .race(id):
                if LocalAssets.shared.loadingDone {
                    RaceScreen(model: model).id(id)
                } else {
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large).tint(Theme.accent)
                        Text("Ładowanie aut…").font(Theme.display(24))
                    }
                }
            }
        }
        .background(Color.black)
        .onAppear { AudioManager.shared.start() }
        .onChange(of: model.screen, initial: true) { _, screen in
            if case .race = screen { AudioManager.shared.play(.race) } else { AudioManager.shared.play(.menu) }
        }
    }
}

/// Scena 3D z autem na podeście — wspólna dla menu i garażu.
private struct PreviewStage: View {
    let preview: GaragePreview
    let model: AppModel
    let narrow: Bool

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            content.add(preview.root)
            preview.subscription?.cancel()
            preview.subscription = content.subscribe(to: SceneEvents.Update.self) { [weak preview] event in
                MainActor.assumeIsolated { preview?.update(dt: event.deltaTime) }
            }
        } update: { _ in
            // Odczyt licznika podpina odświeżenie, gdy dojdzie realistyczny model.
            _ = LocalAssets.shared.loadedCount
            preview.show(def: model.previewCar, colorHex: model.profile.colorHex)
            preview.setLayout(model.screen == .garage ? .garage : .menu, narrow: narrow)
        }
    }
}
