import Foundation
import Observation
import RaceCore

/// Wybrane auto i kolor lakieru. Zapisywane lokalnie na iPadzie (UserDefaults).
struct Profile: Codable, Equatable {
    var carId: String
    var colorHex: String

    static let `default` = Profile(carId: CarCatalog.all[0].id, colorHex: CarCatalog.colors[0])
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
        didSet { save() }
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
