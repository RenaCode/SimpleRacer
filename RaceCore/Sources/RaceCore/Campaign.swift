import Foundation

/// Ulepszenie auta — każde ma 5 poziomów, każdy poziom +4% danej cechy.
public enum Upgrade: String, CaseIterable, Codable, Sendable {
    case engine, acceleration, handling, nitro

    public var name: String {
        switch self {
        case .engine: "Silnik"
        case .acceleration: "Przyspieszenie"
        case .handling: "Prowadzenie"
        case .nitro: "Nitro"
        }
    }
}

/// Postęp gracza w kampanii. Zapisywany na urządzeniu.
public struct CampaignState: Codable, Equatable, Sendable {
    public var coins: Int = 0
    /// Najlepsze gwiazdki na trasie (id trasy → 1…3).
    public var bestStars: [Int: Int] = [:]
    public var ownedCars: Set<String> = []
    /// Poziomy ulepszeń: id auta → (ulepszenie → poziom 0…5).
    public var upgrades: [String: [Upgrade: Int]] = [:]

    public init(coins: Int = 0, ownedCars: Set<String> = []) {
        self.coins = coins
        self.ownedCars = ownedCars
    }

    public var totalStars: Int { bestStars.values.reduce(0, +) }

    public func level(_ u: Upgrade, car: String) -> Int { upgrades[car]?[u] ?? 0 }
}

/// Zasady kampanii: moc aut, wymagania tras, nagrody, ulepszenia, odblokowania.
/// Strojenie pod dzieci: trasy łatwe, nagrody hojne, ulepszenia tanie.
public enum Campaign {
    public static let maxLevel = 5
    public static let upgradeStep = 0.04
    /// Auto, które gracz ma od początku (aplikacja może je zmienić, gdy używa własnych modeli).
    public static var starterCar = "strzala"
    /// Gwiazdki potrzebne do wejścia do krainy (Miasto, Wybrzeże, Pustynia, Las, Śnieg).
    public static let starsToUnlock = [0, 10, 22, 36, 52]
    /// Pełna wersja: wszystkie auta w garażu i wszystkie trasy otwarte — bez kupowania aut za monety
    /// i bez zbierania gwiazdek. Ustawia aplikacja (`FullVersion`); domyślnie wyłączona.
    /// Moc wymagana na trasie i ulepszenia za monety działają tak samo (to zasady gry, nie blokada).
    public static var fullVersion = false

    public static func newGame() -> CampaignState { CampaignState(coins: 0, ownedCars: [starterCar]) }

    /// Moc auta (jak „PR” w grach mobilnych): jedna liczba z prędkości, przyspieszenia, prowadzenia i nitro.
    public static func rating(_ def: CarDef) -> Int {
        Int((def.topSpeed * 4 + def.accel * 10 + def.handling * 100 + def.nitroPower * 100).rounded())
    }

    /// Auto z naniesionymi ulepszeniami.
    public static func upgraded(_ def: CarDef, levels: [Upgrade: Int]) -> CarDef {
        var d = def
        func k(_ u: Upgrade) -> Double { 1 + upgradeStep * Double(min(maxLevel, levels[u] ?? 0)) }
        d.topSpeed *= k(.engine)
        d.accel *= k(.acceleration)
        d.handling *= k(.handling)
        d.nitroPower *= k(.nitro)
        return d
    }

    public static func upgraded(_ def: CarDef, in state: CampaignState) -> CarDef {
        upgraded(def, levels: state.upgrades[def.id] ?? [:])
    }

    /// Najmniej ulepszeń (po kolei: silnik, przyspieszenie, prowadzenie, nitro), które dają co najmniej `rating`.
    public static func minimalUpgrades(_ def: CarDef, toReach target: Int) -> [Upgrade: Int] {
        var levels: [Upgrade: Int] = [:]
        for lvl in 1...maxLevel {
            for u in Upgrade.allCases where rating(upgraded(def, levels: levels)) < target { levels[u] = lvl }
            if rating(upgraded(def, levels: levels)) >= target { break }
        }
        return levels
    }

    /// O ile rywale są słabsi od mocy wymaganej na trasie (gra dla dzieci).
    public static let rivalHandicap = 25

    /// Rywal na trasie: wygląd (model, nazwa) z dowolnego auta, ale statystyki auta startowego
    /// ulepszonego tylko do mocy nieco poniżej wymaganej na tej trasie — żeby rywale nie byli za mocni.
    public static func rival(looking visual: CarDef, on spec: TrackSpec) -> CarDef {
        let base = CarCatalog.car(id: starterCar)
        let stats = upgraded(base, levels: minimalUpgrades(base, toReach: requiredRating(spec) - rivalHandicap))
        var d = visual
        d.topSpeed = stats.topSpeed
        d.accel = stats.accel
        d.handling = stats.handling
        d.nitroPower = stats.nitroPower
        return d
    }

    /// Koszt wejścia na `level` (1…5).
    public static func upgradeCost(toLevel level: Int) -> Int { 100 * level }

    /// Cena auta w monetach; auto startowe za darmo.
    public static func price(of def: CarDef) -> Int {
        def.id == starterCar ? 0 : max(500, (rating(def) - 650) * 20)
    }

    /// Moc wymagana na trasie: od 650 (pierwsze trasy — każde auto) do 820 (auto startowe po ulepszeniach).
    public static func requiredRating(_ spec: TrackSpec) -> Int { 650 + Int((170 * spec.difficulty).rounded()) }

    /// Umiejętność rywali: wolni na początku, nieco szybsi pod koniec — ale zawsze łatwo.
    public static func aiSkill(_ spec: TrackSpec) -> Double { 0.8 + 0.1 * spec.difficulty }

    /// Gwiazdki za miejsce: wygrana 3, podium 2, każde dojechanie 1.
    public static func stars(place: Int) -> Int { place == 1 ? 3 : (place <= 3 ? 2 : 1) }

    /// Monety za wyścig: więcej za trudniejsze trasy i lepsze miejsca, plus premia za takedowny.
    public static func reward(_ spec: TrackSpec, place: Int, takedowns: Int) -> Int {
        let base = 160 + 160 * spec.difficulty
        let factor = switch place {
        case 1: 1.0
        case 2: 0.8
        case 3: 0.65
        default: 0.45
        }
        return Int((base * factor).rounded()) + 20 * takedowns
    }

    /// Czy gracz ma auto: kupione albo dane przez pełną wersję.
    public static func owns(_ car: String, _ state: CampaignState) -> Bool {
        fullVersion || state.ownedCars.contains(car)
    }

    public static func isRegionUnlocked(_ region: Region, _ state: CampaignState) -> Bool {
        fullVersion || state.totalStars >= starsToUnlock[region.rawValue]
    }

    /// Trasa dostępna: kraina odblokowana, a poprzednia trasa w tej krainie ukończona.
    public static func isUnlocked(_ spec: TrackSpec, _ state: CampaignState) -> Bool {
        if fullVersion { return true }
        guard isRegionUnlocked(spec.region, state) else { return false }
        let first = spec.region.rawValue * TrackCatalog.perRegion + 1
        return spec.id == first || (state.bestStars[spec.id - 1] ?? 0) > 0
    }

    /// Trasa dla przycisku „Ścigaj się”: pierwsza dostępna bez gwiazdek, a gdy wszystkie dostępne są
    /// zaliczone — ostatnia dostępna.
    public static func nextTrack(_ state: CampaignState) -> TrackSpec {
        let open = TrackCatalog.all.filter { isUnlocked($0, state) }
        return open.first { (state.bestStars[$0.id] ?? 0) == 0 } ?? open.last ?? TrackCatalog.all[0]
    }

    /// Czy auto ma dość mocy na trasę.
    public static func canRace(_ def: CarDef, on spec: TrackSpec, _ state: CampaignState) -> Bool {
        rating(upgraded(def, in: state)) >= requiredRating(spec)
    }

    public enum UpgradeError: Error, Equatable { case maxLevel, notEnoughCoins, notOwned }
    public enum PurchaseError: Error, Equatable { case alreadyOwned, notEnoughCoins }

    public static func buyUpgrade(_ u: Upgrade, car: String, _ state: inout CampaignState) throws(UpgradeError) {
        guard owns(car, state) else { throw .notOwned }
        let next = state.level(u, car: car) + 1
        guard next <= maxLevel else { throw .maxLevel }
        let cost = upgradeCost(toLevel: next)
        guard state.coins >= cost else { throw .notEnoughCoins }
        state.coins -= cost
        state.upgrades[car, default: [:]][u] = next
    }

    public static func buyCar(_ def: CarDef, _ state: inout CampaignState) throws(PurchaseError) {
        guard !owns(def.id, state) else { throw .alreadyOwned }
        let p = price(of: def)
        guard state.coins >= p else { throw .notEnoughCoins }
        state.coins -= p
        state.ownedCars.insert(def.id)
    }

    /// Wynik wyścigu: zapamiętuje lepsze gwiazdki, dodaje monety. Zwraca (gwiazdki, monety, nowy rekord).
    @discardableResult
    public static func record(_ spec: TrackSpec, place: Int, takedowns: Int,
                              _ state: inout CampaignState) -> (stars: Int, coins: Int, newBest: Bool) {
        let s = stars(place: place)
        let coins = reward(spec, place: place, takedowns: takedowns)
        let newBest = s > (state.bestStars[spec.id] ?? 0)
        if newBest { state.bestStars[spec.id] = s }
        state.coins += coins
        return (s, coins, newBest)
    }
}
