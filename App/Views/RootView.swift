import RaceCore
import RealityKit
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var preview = GaragePreview()
    /// Splash przy starcie: zasłania menu, dopóki tło garażu i auto gracza nie są gotowe.
    @State private var splash = true
    /// Menu przyjmuje dotyk (i jest widoczne dla dostępności) dopiero po wygaszeniu splasha — w czasie
    /// 0,4 s animacji znikająca nakładka dalej przechwytuje dotyk.
    @State private var menuReady = false

    var body: some View {
        ZStack {
            switch model.screen {
            case .menu, .garage:
                let _ = debugLog("ekran: \(model.screen == .menu ? "menu" : "garaż")")
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
                // Ekran wyścigu sam czeka na auta i tekstury, pokazując ekran ładowania z postępem.
                RaceScreen(model: model).id(id)
            }
        }
        // Pod splashem menu już istnieje, ale dotyk trafia w splash, także w trakcie jego wygaszania — test UI
        // widział przycisk „Garaż” i stukał w zasłonę (testMenuGarageCampaignRace: „po tapnięciu Garaż zostaje menu”;
        // nagranie testu: stuknięcie w 7,72 s, splash w połowie wygaszania).
        .accessibilityHidden(!menuReady)
        .overlay {
            if splash { SplashView().transition(.opacity) }
        }
        .background(Color.black)
        .task { await startUp() }
        .onAppear { AudioManager.shared.start() }
        .onChange(of: model.screen, initial: true) { _, screen in
            if case .race = screen { AudioManager.shared.play(.race) } else { AudioManager.shared.play(.menu) }
        }
    }
}

extension RootView {
    /// Start: tło garażu w tle, auto gracza (najwyżej 4 s czekania), potem zdjęcie splasha
    /// i — w czasie, gdy dziecko jest w menu — przygotowanie krainy następnej trasy.
    private func startUp() async {
        let start = ProcessInfo.processInfo.systemUptime
        // Shadery obróbki obrazu kompilują się w tle, zanim dziecko wybierze trasę.
        PostFXPipelines.warmUp()
        // Najpierw pierwszy widok 3D: tworzenie tekstur w tle, zanim RealityKit się zainicjalizuje,
        // psuło cały proces (żaden model się nie wczytywał, a potem awaria).
        // Start prosto w wyścigu (argument testowy): splash znika, wyścig ma własny ekran ładowania.
        if case .race = model.screen {
            splash = false
            menuReady = true
            await LocalAssets.shared.preload(first: model.profile.carId)
            return
        }
        // Start prosto w kampanii (argument testowy `-screen campaign`): sceny garażu nie ma, więc nie ma na co czekać.
        if model.screen == .campaign {
            splash = false
            menuReady = true
            await LocalAssets.shared.preload(first: model.profile.carId)
            return
        }
        // Modele aut dopiero po podpięciu pierwszego widoku 3D: wczytywanie USDZ przed inicjalizacją
        // RealityKit co kilkanaście startów psuło proces (żaden model się nie wczytywał, potem awaria).
        while !preview.attached { try? await Task.sleep(for: .milliseconds(20)) }
        let carId = model.profile.carId
        Task { await LocalAssets.shared.preload(first: carId) }
        await preview.loadBackdrop()
        while !LocalAssets.shared.isLoaded(model.car), ProcessInfo.processInfo.systemUptime - start < 4 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(150)) // klatka z autem zdąży się narysować
        debugLog(String(format: "start: menu gotowe po %.2f s", ProcessInfo.processInfo.systemUptime - start))
        withAnimation(.easeOut(duration: 0.4)) { splash = false } completion: { menuReady = true }
        // Wyścig już się ładuje (np. -autostartRace) — on sam przygotuje swoją krainę.
        if case .race = model.screen { return }
        await ScenePreloader.shared.prepare(Campaign.nextTrack(model.campaign, car: model.car).region)
    }
}

/// Ekran startowy: baner z logo na ciemnym tle i pasek, który pokazuje, że gra pracuje.
private struct SplashView: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.1), .black], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 40) {
                LogoBanner().scaleEffect(1.3)
                ProgressBar(value: 1).frame(width: 300).opacity(0.9)
            }
        }
        .ignoresSafeArea()
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
            preview.attached = true
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
        // Wyjście do wyścigu: subskrypcja klatek trzymała przy życiu całą scenę menu (+ ok. 470 MB) i na iPadzie
        // A16 każdy wyścig po menu jechał ok. 20 kl./s (prosto w wyścig: płynnie). Scenę odpinamy; przy powrocie
        // RealityView podpina ją od nowa.
        .onDisappear {
            preview.subscription?.cancel()
            preview.subscription = nil
            preview.root.removeFromParent()
            #if DEBUG || FAMILY
            debugLog(String(format: "menu: scena odpięta, pamięć %.0f MB", memoryFootprintMB()))
            #endif
        }
    }
}
