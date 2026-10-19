import Foundation
import Observation
import RaceCore

/// Wybrane auto i kolor lakieru. Zapisywane lokalnie na iPadzie (UserDefaults).
struct Profile: Codable, Equatable {
    var carId: String
    var colorHex: String
    /// Auto-prowadzenie: auto samo trzyma tor, ◀ ▶ zmieniają pas. Domyślnie włączone (dla dzieci).
    var autoSteer: Bool = true
    var musicOn: Bool = true
    var soundOn: Bool = true

    static let `default` = Profile(carId: CarCatalog.all[0].id, colorHex: CarCatalog.colors[0])

    init(carId: String, colorHex: String, autoSteer: Bool = true) {
        self.carId = carId
        self.colorHex = colorHex
        self.autoSteer = autoSteer
    }

    // Zapis z wcześniejszej wersji nie ma `autoSteer` — wtedy przyjmujemy domyślne.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        carId = try c.decode(String.self, forKey: .carId)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        autoSteer = try c.decodeIfPresent(Bool.self, forKey: .autoSteer) ?? true
        musicOn = try c.decodeIfPresent(Bool.self, forKey: .musicOn) ?? true
        soundOn = try c.decodeIfPresent(Bool.self, forKey: .soundOn) ?? true
    }
}

struct RaceResult: Equatable {
    var position: Int
    var total: Int
    var time: Double
    var takedowns: Int
    var carName: String
    var trackId: Int = 1
    /// Rozliczenie kampanii (uzupełnia AppModel po wyścigu).
    var stars = 0
    var coins = 0
    var newBest = false
    /// Następna trasa, jeśli właśnie się odblokowała albo była już dostępna.
    var nextTrackId: Int?
}

@MainActor
@Observable
final class AppModel {
    enum Screen: Equatable {
        case menu
        case garage
        case campaign
        /// Nowy identyfikator = nowy wyścig od zera („Jeszcze raz”).
        case race(UUID)
    }

    var screen: Screen = .menu
    var profile: Profile {
        didSet {
            save()
            AudioManager.shared.musicOn = profile.musicOn
            AudioManager.shared.soundOn = profile.soundOn
        }
    }

    /// Postęp kampanii (gwiazdki, monety, auta, ulepszenia) — zapisywany na urządzeniu.
    var campaign: CampaignState {
        didSet { saveCampaign() }
    }
    /// Trasa wybrana do najbliższego wyścigu.
    var trackId = 1

    private static let key = "simpleracer.profile"
    private static let campaignKey = "simpleracer.campaign"

    init() {
        debugLog("start: AppModel")
        LocalAssets.shared.registerCars()
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let p = try? JSONDecoder().decode(Profile.self, from: data),
           CarCatalog.all.contains(where: { $0.id == p.carId }),
           UIColorHex.isValid(p.colorHex) {
            profile = p
        } else {
            profile = .default
        }
        if let data = UserDefaults.standard.data(forKey: Self.campaignKey),
           let c = try? JSONDecoder().decode(CampaignState.self, from: data) {
            campaign = c
        } else {
            campaign = Campaign.newGame()
        }
        // Auto startowe zawsze w garażu; jeździ się tylko własnym autem, które istnieje w katalogu.
        campaign.ownedCars.insert(Campaign.starterCar)
        if !campaign.ownedCars.contains(profile.carId) || !CarCatalog.all.contains(where: { $0.id == profile.carId }) {
            profile.carId = Campaign.starterCar
        }
        AudioManager.shared.musicOn = profile.musicOn
        AudioManager.shared.soundOn = profile.soundOn
        let first = profile.carId
        Task { await LocalAssets.shared.preload(first: first) }
        Task { await ModelLibrary.shared.prefetch() }
        #if DEBUG || FAMILY
        // Do testów w symulatorze z wiersza poleceń: `simctl launch <udid> com.renacode.simpleracer -autostartRace`.
        // `-mute` wycisza muzykę i efekty (testy w symulatorze grają przez głośniki Maca).
        if ProcessInfo.processInfo.arguments.contains("-mute") {
            // W init `didSet` nie działa — dźwięk wyciszamy i zapisujemy wprost.
            profile.musicOn = false
            profile.soundOn = false
            AudioManager.shared.musicOn = false
            AudioManager.shared.soundOn = false
            save()
        }
        if ProcessInfo.processInfo.arguments.contains("-autostartRace") { startRace() }
        // `-car <id>` wybiera auto (podgląd modeli w symulatorze).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-car"), i + 1 < args.count, CarCatalog.all.contains(where: { $0.id == args[i + 1] }) {
            campaign.ownedCars.insert(args[i + 1])
            profile.carId = args[i + 1]
        }
        // `-rich` daje monety i gwiazdki (podgląd sklepu i odblokowań).
        if args.contains("-rich") {
            campaign.coins = 20_000
            for spec in TrackCatalog.all.prefix(20) { campaign.bestStars[spec.id] = 3 }
        }
        if let i = args.firstIndex(of: "-track"), i + 1 < args.count, let id = Int(args[i + 1]) { trackId = id }
        // `-toggleMuteAt <s>` przełącza wyciszenie po <s> sekundach (test zawieszania przy wyciszaniu).
        if let i = args.firstIndex(of: "-toggleMuteAt"), i + 1 < args.count, let t = Double(args[i + 1]) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(t))
                debugLog("test: przełączam wyciszenie")
                self?.profile.soundOn.toggle()
            }
        }
        // `-raceAfter <s>` naciska „Ścigaj się” po <s> sekundach w menu (pomiar ładowania jak u dziecka).
        if let i = args.firstIndex(of: "-raceAfter"), i + 1 < args.count, let t = Double(args[i + 1]) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(t))
                guard let self else { return }
                debugLog("test: Ścigaj się")
                self.startRace(track: Campaign.nextTrack(self.campaign).id)
            }
        }
        if let i = args.firstIndex(of: "-screen"), i + 1 < args.count {
            screen = ["campaign": .campaign, "garage": .garage][args[i + 1]] ?? .menu
        }
        #endif
    }

    var car: CarDef { CarCatalog.car(id: profile.carId) }
    /// Auto oglądane w garażu (może być jeszcze nie kupione); nil = auto gracza.
    var garageCarId: String?
    var previewCar: CarDef { garageCarId.map(CarCatalog.car) ?? car }
    /// Auto gracza z ulepszeniami — tym się jeździ.
    var playerCar: CarDef { Campaign.upgraded(car, in: campaign) }
    var track: TrackSpec { TrackCatalog.track(id: trackId) }

    func startRace() { screen = .race(UUID()) }

    func startRace(track id: Int) {
        trackId = id
        startRace()
    }

    /// Rozlicza wyścig w kampanii: gwiazdki, monety, następna trasa.
    func settle(_ r: RaceResult) -> RaceResult {
        var out = r
        let spec = TrackCatalog.track(id: r.trackId)
        let reward = Campaign.record(spec, place: r.position, takedowns: r.takedowns, &campaign)
        out.stars = reward.stars
        out.coins = reward.coins
        out.newBest = reward.newBest
        if r.trackId < TrackCatalog.count {
            let next = TrackCatalog.track(id: r.trackId + 1)
            if Campaign.isUnlocked(next, campaign) { out.nextTrackId = next.id }
        }
        return out
    }

    private func saveCampaign() {
        if let data = try? JSONEncoder().encode(campaign) {
            UserDefaults.standard.set(data, forKey: Self.campaignKey)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
