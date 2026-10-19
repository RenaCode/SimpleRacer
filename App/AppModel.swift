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
}

@MainActor
@Observable
final class AppModel {
    enum Screen: Equatable {
        case menu
        case garage
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

    private static let key = "simpleracer.profile"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let p = try? JSONDecoder().decode(Profile.self, from: data),
           CarCatalog.all.contains(where: { $0.id == p.carId }),
           UIColorHex.isValid(p.colorHex) {
            profile = p
        } else {
            profile = .default
        }
        AudioManager.shared.musicOn = profile.musicOn
        AudioManager.shared.soundOn = profile.soundOn
        #if DEBUG
        // Do testów w symulatorze z wiersza poleceń: `simctl launch <udid> com.renacode.simpleracer -autostartRace`.
        if ProcessInfo.processInfo.arguments.contains("-autostartRace") { startRace() }
        #endif
    }

    var car: CarDef { CarCatalog.car(id: profile.carId) }

    func startRace() { screen = .race(UUID()) }

    private func save() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
