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

/// Model otoczenia (budynek, drzewo, krzak, tło) z `scenery.json`.
struct SceneryEntry: Decodable {
    var file: String
    var kind: String
    /// Nazwa węzła, którego dzieci to osobne obiekty (np. paczka budynków).
    var split: String?
    /// Tylko te węzły (np. góry i las w tle z większej sceny).
    var only: [String]?
    var regions: [String]
    var height: [Double]
    var max: Int?
    var author: String
    var license: String
    var source: String
    var title: String
}

/// Pojedynczy obiekt otoczenia gotowy do klonowania: wyśrodkowany w X/Z, stoi na y = 0, w skali pliku.
struct SceneryPiece {
    let entry: SceneryEntry
    let template: Entity
    let height: Float
    let footprint: Float
    var regions: Set<String> { Set(entry.regions) }
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
    @ObservationIgnored private(set) var sceneryEntries: [SceneryEntry] = []
    /// Obiekty otoczenia wg rodzaju ("building", "tree", "bush", "backdrop").
    @ObservationIgnored private(set) var scenery: [String: [SceneryPiece]] = [:]

    /// Realistyczne otoczenie 3D (budynki, drzewa, góry) — wyłączone: wyglądało źle i spowalniało grę.
    /// Daleki plan to teraz panorama krainy (SkyEnvironment), bliski — lekkie modele Kenney.
    static let sceneryEnabled = false

    func scenery(_ kind: String, region: Region) -> [SceneryPiece] {
        guard Self.sceneryEnabled else { return [] }
        return (scenery[kind] ?? []).filter { $0.regions.contains(Self.regionKey(region)) }
    }

    static func regionKey(_ r: Region) -> String {
        switch r {
        case .city: "city"
        case .coast: "coast"
        case .desert: "desert"
        case .forest: "forest"
        case .snow: "snow"
        }
    }

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
        // Gdy są własne modele, gra używa tylko ich (Kenney zostaje jako zapas na czas wczytywania).
        CarCatalog.replaceAll(with: cars.map { e in
            CarDef(id: e.id, name: e.name, description: "\(e.author) · \(e.license)",
                   topSpeed: e.topSpeed, accel: e.accel, handling: e.handling, nitroPower: e.nitroPower,
                   shape: fallback.shape, model: fallback.model,
                   realistic: RealisticModelRef(file: e.file, paintParts: e.paint, yawDegrees: e.yaw,
                                                commercial: e.commercial, author: e.author, license: e.license,
                                                source: e.source))
        })
        if cars.isEmpty {
            loadingDone = true
        } else {
            // Auto startowe: pierwsze z licencją komercyjną (do wersji płatnej), inaczej pierwsze w ogóle.
            Campaign.starterCar = (cars.first { $0.commercial } ?? cars[0]).id
        }
    }

    func isLoaded(_ def: CarDef) -> Bool {
        def.realistic.map { templates[$0.file] != nil } ?? true
    }

    /// Wczytane auta (do wyglądu rywali); gdy jeszcze żadne — cały katalog.
    var loadedCars: [CarDef] {
        let ready = CarCatalog.all.filter { $0.realistic.map { templates[$0.file] != nil } ?? false }
        return ready.isEmpty ? CarCatalog.all : ready
    }

    /// Wczytuje modele w tle — najpierw auto gracza, potem reszta równolegle.
    /// Do czasu wczytania auto ma model zapasowy (Kenney).
    func preload(first: String? = nil) async {
        guard let folder else { return }
        let ordered = cars.sorted { a, _ in a.id == first }
        if let head = ordered.first { await load(head, from: folder) }
        await withTaskGroup(of: Void.self) { group in
            for e in ordered.dropFirst() {
                group.addTask { await self.load(e, from: folder) }
            }
        }
        if Self.sceneryEnabled { await preloadScenery(from: folder) }
        loadingDone = true
        debugLog("model: wszystkie wczytane")
    }

    /// Modele otoczenia: paczki rozbite na pojedyncze obiekty, każdy wyśrodkowany i postawiony na ziemi.
    private func preloadScenery(from folder: URL) async {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("scenery.json")),
              let entries = try? JSONDecoder().decode([SceneryEntry].self, from: data) else { return }
        let fm = FileManager.default
        sceneryEntries = entries.filter { fm.fileExists(atPath: folder.appendingPathComponent($0.file).path) }
        await withTaskGroup(of: Void.self) { group in
            for e in sceneryEntries {
                group.addTask { await self.loadScenery(e, from: folder) }
            }
        }
    }

    private func loadScenery(_ e: SceneryEntry, from folder: URL) async {
        guard let entity = try? await Entity(contentsOf: folder.appendingPathComponent(e.file)) else {
            debugLog("otoczenie: \(e.file) — błąd wczytania")
            return
        }
        var parts: [Entity] = []
        if let split = e.split, let node = entity.findEntity(named: split) {
            parts = Array(node.children)
        } else if let only = e.only {
            parts = only.compactMap { entity.findEntity(named: $0) }
        } else {
            parts = [entity]
        }
        var pieces: [SceneryPiece] = []
        for part in parts {
            // Zachowujemy transformację części względem pliku (skala, obrót z eksportu).
            let world = part.transformMatrix(relativeTo: nil)
            part.removeFromParent()
            part.setTransformMatrix(world, relativeTo: nil)
            let root = Entity()
            root.addChild(part)
            let b = part.visualBounds(relativeTo: root)
            guard b.extents.y > 0.001 else { continue }
            part.position -= SIMD3<Float>(b.center.x, b.min.y, b.center.z)
            pieces.append(SceneryPiece(entry: e, template: root, height: b.extents.y,
                                       footprint: max(b.extents.x, b.extents.z)))
        }
        scenery[e.kind, default: []] += pieces
        debugLog("otoczenie: \(e.file) — \(pieces.count) obiektów")
    }

    private func load(_ e: LocalCarEntry, from folder: URL) async {
        guard templates[e.file] == nil else { return }
        if let entity = try? await Entity(contentsOf: folder.appendingPathComponent(e.file)) {
            templates[e.file] = Self.normalized(entity, yawDegrees: e.yaw)
            loadedCount += 1
            debugLog("model: \(e.file) wczytany")
        } else {
            debugLog("model: \(e.file) — błąd wczytania")
        }
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
            Credit(title: "Panoramy krain (Wide Street 01, Spiaggia di Mondello, Goegap, Je Gray 02, Snowy Hillside)",
                   author: "Poly Haven (polyhaven.com)", license: "CC0", source: "https://polyhaven.com/hdris"),
        ]
        out += cars.map { Credit(title: $0.name, author: $0.author, license: $0.license, source: $0.source) }
        out += sceneryEntries.map { Credit(title: $0.title, author: $0.author, license: $0.license, source: $0.source) }
        return out
    }
}
