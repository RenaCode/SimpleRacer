import RaceCore
import RealityKit
import SwiftUI

/// Ekran wyścigu. Gra powstaje raz, przy pierwszym pokazaniu ekranu — nie w `init`, bo SwiftUI
/// tworzy widok od nowa przy każdej zmianie modelu (np. wyciszeniu), a budowa sceny trwa sekundy.
struct RaceScreen: View {
    let model: AppModel
    @State private var game: RaceGame?
    @State private var revealed = false
    @State private var progress = 0.0

    var body: some View {
        ZStack {
            if let game {
                RaceContent(model: model, game: game)
            }
            if !revealed {
                LoadingView(spec: model.track, progress: progress)
                    .transition(.opacity)
            }
        }
        .background(Color.black)
        .task { await load() }
    }

    /// Ładowanie jak w silnikach gier: ekran ładowania od razu, ciężka praca w tle z prawdziwym postępem,
    /// a scena rozgrzewa się (pierwsze klatki, shadery, efekty) pod zasłoną, zanim ruszy odliczanie.
    private func load() async {
        guard game == nil else { return }
        let start = ProcessInfo.processInfo.systemUptime
        let assets = LocalAssets.shared, scenery = ScenePreloader.shared
        let spec = model.track
        // 1. Auta (0–45%) i 2. tekstury krainy (45–90%) — równolegle.
        async let sceneryDone: Void = scenery.prepare(spec.region)
        while !assets.loadingDone || !scenery.isReady(spec.region) {
            let cars = assets.cars.isEmpty ? 1 : Double(assets.loadedCount) / Double(assets.cars.count)
            progress = 0.45 * min(1, cars) + 0.45 * (scenery.isReady(spec.region) ? 1 : scenery.progress)
            try? await Task.sleep(for: .milliseconds(50))
        }
        await sceneryDone
        progress = 0.9
        // 3. Budowa sceny (szybka — tekstury gotowe), 4. rozgrzewka pod zasłoną.
        try? await Task.sleep(for: .milliseconds(30)) // pasek zdąży się narysować
        var profile = model.profile
        #if DEBUG || FAMILY
        // `-manualSteer`: wyścig bez auto-prowadzenia (testy UI). Tylko ten wyścig — nic nie trafia do profilu,
        // inaczej następne uruchomienia (testy i gra na symulatorze) jeździłyby bez sterowania.
        if ProcessInfo.processInfo.arguments.contains("-manualSteer") { profile.autoSteer = false }
        #endif
        let g = RaceGame(profile: profile, spec: spec, playerCar: model.playerCar)
        game = g
        while g.warmFrames < 20 { try? await Task.sleep(for: .milliseconds(30)) }
        progress = 1
        // Ekran ładowania nie miga: co najmniej 0,8 s.
        let shown = ProcessInfo.processInfo.systemUptime - start
        if shown < 0.8 { try? await Task.sleep(for: .seconds(0.8 - shown)) }
        debugLog(String(format: "ładowanie wyścigu: %.2f s", ProcessInfo.processInfo.systemUptime - start))
        withAnimation(.easeOut(duration: 0.4)) { revealed = true }
        g.release()
    }
}

private struct RaceContent: View {
    let model: AppModel
    let game: RaceGame
    @Environment(\.scenePhase) private var scenePhase
    /// Wynik rozliczony w kampanii (gwiazdki, monety) — raz na wyścig.
    @State private var settled: RaceResult?

    /// Smugi prędkości: pełne przy nitro, słabe od 260 km/h.
    private var speedLineIntensity: Double {
        let hud = game.hud
        if game.result != nil || game.paused { return 0 }
        if hud.mode != .off { return hud.mode == .normal ? 0.8 : 1 }
        return min(0.4, max(0, (hud.speedKmh - 260) / 100))
    }

    var body: some View {
        ZStack {
            RealityView { content in
                content.camera = .virtual
                // Wygładzanie krawędzi (linie jezdni, krawędzie budynków i aut) i obróbka obrazu (iOS 26+).
                #if DEBUG || FAMILY
                if !ProcessInfo.processInfo.arguments.contains("-noMSAA") { content.renderingEffects.antialiasing = .multisample4X }
                #else
                content.renderingEffects.antialiasing = .multisample4X
                #endif
                #if DEBUG || FAMILY
                let postFXOn = !ProcessInfo.processInfo.arguments.contains("-noPostFX")
                #else
                let postFXOn = true
                #endif
                if #available(iOS 26.0, *), postFXOn {
                    content.renderingEffects.customPostProcessing = .effect(RacePostEffect(settings: game.postFX))
                    debugLog("obróbka obrazu: włączona")
                }
                content.add(game.root)
                let game = self.game
                // Słaba referencja: gra trzyma subskrypcję, więc mocna dawałaby cykl i wyciek całej sceny po każdym wyścigu.
                game.subscription = content.subscribe(to: SceneEvents.Update.self) { [weak game] event in
                    MainActor.assumeIsolated { game?.update(dt: event.deltaTime) }
                }
            }
            .ignoresSafeArea()

            SpeedLines(intensity: speedLineIntensity)
                .animation(.easeOut(duration: 0.4), value: speedLineIntensity)
            HudView(game: game)
                .opacity(game.result == nil ? 1 : 0.25)
            // Po mecie (3 s do ekranu wyników) bez pauzy: „Menu” albo „Od nowa” w tym oknie
            // przerywały wyścig przed rozliczeniem i ukończona trasa nie dawała gwiazdek ani monet.
            if game.result == nil && game.phase != .finished {
                TouchControls(input: game.input)
                PauseButton(muted: !model.profile.musicOn && !model.profile.soundOn,
                            pause: { game.paused = true },
                            toggleMute: {
                                let mute = model.profile.musicOn || model.profile.soundOn
                                model.profile.musicOn = !mute
                                model.profile.soundOn = !mute
                            })
            }
            if game.paused && game.result == nil {
                PauseView(resume: { game.paused = false },
                          restart: { model.startRace() },
                          menu: { model.screen = .menu })
            }
            if game.buildFailed {
                TrackErrorView(retry: { model.startRace() }, menu: { model.screen = .menu })
            }
            if let r = settled {
                ResultsView(result: r,
                            next: r.nextTrackId.map { id in { model.startRace(track: id) } },
                            again: { model.startRace() },
                            garage: { model.screen = .garage },
                            campaign: { model.screen = .campaign })
            }
        }
        .onChange(of: game.result) { _, r in
            if let r, settled == nil { settled = model.settle(r) }
        }
        .onAppear {
            game.input.onEscape = { [weak game] in
                guard let game, game.phase != .finished else { return }
                game.paused.toggle()
            }
        }
        // Wyjście z aplikacji, powiadomienie albo centrum sterowania — gra staje i czeka.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && game.result == nil && game.phase != .finished { game.paused = true }
        }
        .onDisappear {
            game.subscription?.cancel()
            AudioManager.shared.setEngine(speed: 0, nitro: false, running: false)
        }
    }
}

/// Pauza i wyciszenie u góry ekranu.
private struct PauseButton: View {
    let muted: Bool
    let pause: () -> Void
    let toggleMute: () -> Void

    var body: some View {
        VStack {
            HStack(spacing: 14) {
                round(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: muted ? "Włącz dźwięk" : "Wycisz", toggleMute)
                round("pause.fill", label: "Pauza", pause)
            }
            .padding(.top, 14)
            Spacer()
        }
    }

    private func round(_ icon: String, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.black.opacity(0.35)))
                .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 2))
        }
        .accessibilityLabel(label)
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

/// Budowa trasy się nie udała (np. brak pamięci) — zamiast pustej sceny prośba o ponowną próbę.
private struct TrackErrorView: View {
    let retry: () -> Void
    let menu: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("Nie udało się przygotować trasy")
                    .font(Theme.display(36))
                    .foregroundStyle(.white)
                HStack(spacing: 20) {
                    Button("Spróbuj ponownie", action: retry)
                    Button("Menu", action: menu)
                }
                .font(.system(size: 22, weight: .bold))
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
    }
}
