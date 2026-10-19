import Foundation
import Observation
import RaceCore
import RealityKit

/// Modele realistyczne dostarczane lokalnie: katalog `LocalModels/` (poza repozytorium) kopiowany
/// przy budowaniu do `Models/Realistic`. Modele bez licencji komercyjnej trafiają tylko do buildu Debug.
struct LocalCarEntry: Decodable {
    var id: String
    var name: String
    var file: String
    var commercial: Bool
    var topSpeed: Double
    var accel: Double
    var handling: Double
    var nitroPower: Double
    var paint: [String]
    var yaw: Double
    var author: String
    var license: String
    var source: String
}

struct Credit: Identifiable {
    let id = UUID()
    let title: String
    let author: String
    let license: String
    let source: String
}

@MainActor
@Observable
final class LocalAssets {
    static let shared = LocalAssets()

    /// Ile realistycznych modeli już się wczytało; widoki odświeżają się, gdy rośnie.
    private(set) var loadedCount = 0
    private(set) var loadingDone = false
    @ObservationIgnored private(set) var cars: [LocalCarEntry] = []
    @ObservationIgnored private(set) var templates: [String: Entity] = [:]

    var folder: URL? {
        Bundle.main.url(forResource: "Models", withExtension: nil)?.appendingPathComponent("Realistic")
    }

    /// Czyta cars.json i dopisuje do katalogu auta, których pliki są w paczce aplikacji.
    func registerCars() {
        // cars.json — modele z licencją komercyjną; cars-private.json — tylko w buildzie Debug.
        guard let folder else {
            loadingDone = true
            return
        }
        let entries = ["cars.json", "cars-private.json"].flatMap { name -> [LocalCarEntry] in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return [] }
            return (try? JSONDecoder().decode([LocalCarEntry].self, from: data)) ?? []
        }
        let fm = FileManager.default
        cars = entries.filter { fm.fileExists(atPath: folder.appendingPathComponent($0.file).path) }
        let fallback = CarCatalog.builtIn[0]
        CarCatalog.register(cars.map { e in
            CarDef(id: e.id, name: e.name, description: "\(e.author) · \(e.license)",
                   topSpeed: e.topSpeed, accel: e.accel, handling: e.handling, nitroPower: e.nitroPower,
                   shape: fallback.shape, model: fallback.model,
                   realistic: RealisticModelRef(file: e.file, paintParts: e.paint, yawDegrees: e.yaw,
                                                commercial: e.commercial, author: e.author, license: e.license,
                                                source: e.source))
        })
        if cars.isEmpty { loadingDone = true }
    }

    /// Wczytuje modele w tle po kolei; do czasu wczytania auto ma model zapasowy (Kenney).
    func preload() async {
        guard let folder else { return }
        for e in cars where templates[e.file] == nil {
            if let entity = try? await Entity(contentsOf: folder.appendingPathComponent(e.file)) {
                templates[e.file] = Self.normalized(entity, yawDegrees: e.yaw)
                loadedCount += 1
                debugLog("model: \(e.file) wczytany")
            } else {
                debugLog("model: \(e.file) — błąd wczytania")
            }
        }
        loadingDone = true
    }

    /// Przód w +Z, środek w X/Z w zerze, koła na y = 0, długość 4,5 m.
    private static func normalized(_ model: Entity, yawDegrees: Double) -> Entity {
        let root = Entity()
        let turn = Entity()
        turn.orientation = simd_quatf(angle: Float(yawDegrees * .pi / 180), axis: [0, 1, 0])
        turn.addChild(model)
        root.addChild(turn)
        let b = turn.visualBounds(relativeTo: root)
        let length = max(0.01, b.extents.z)
        let s = 4.5 / length
        turn.scale = [s, s, s]
        let b2 = turn.visualBounds(relativeTo: root)
        turn.position = [-b2.center.x, -b2.min.y, -b2.center.z]
        return root
    }

    var credits: [Credit] {
        var out = [
            Credit(title: "Muzyka „Chiptune Adventures”", author: "Juhani Junkala (SubspaceAudio)", license: "CC0",
                   source: "https://opengameart.org/content/4-chiptunes-adventure"),
            Credit(title: "Modele aut, budynków i toru", author: "Kenney (kenney.nl)", license: "CC0",
                   source: "https://kenney.nl"),
        ]
        out += cars.map { Credit(title: $0.name, author: $0.author, license: $0.license, source: $0.source) }
        return out
    }
}
