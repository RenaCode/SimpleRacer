import Foundation

/// Kraina — wygląd otoczenia trasy (kolor ziemi, budynki, drzewa) i rozdział kampanii.
public enum Region: Int, CaseIterable, Sendable, Codable {
    case city, coast, desert, forest, snow

    public var name: String {
        switch self {
        case .city: "Miasto"
        case .coast: "Wybrzeże"
        case .desert: "Pustynia"
        case .forest: "Las"
        case .snow: "Śnieg"
        }
    }
}

/// Opis trasy w kampanii. Kształt to punkty kontrolne zamkniętego splajnu (jak `TrackData.cityLoop`).
public struct TrackSpec: Identifiable, Sendable {
    /// Numer 1…40.
    public let id: Int
    public let name: String
    public let region: Region
    public let points: [SIMD2<Double>]
    public let halfWidth: Double
    public let laps: Int
    /// 0…1 w obrębie całej kampanii — rośnie z numerem trasy.
    public let difficulty: Double

    public func makeTrack() -> Track { Track(points: points, halfWidth: halfWidth) }
}

/// 40 tras kampanii: pierwsza to ręcznie zaprojektowana pętla miejska, reszta z generatora.
public enum TrackCatalog {
    public static let perRegion = 8
    public static let count = Region.allCases.count * perRegion

    public static let all: [TrackSpec] = (1...count).map(make)

    public static func track(id: Int) -> TrackSpec { all[max(0, min(all.count - 1, id - 1))] }

    private static let names: [[String]] = [
        ["Rondo Startowe", "Aleja Świateł", "Most Neonów", "Pętla Ratusza", "Kanion Wieżowców", "Tunel Nocny", "Bulwar Turbo", "Wielka Metropolia"],
        ["Plaża Mew", "Latarnia", "Klif Wiatru", "Port Rybacki", "Zatoka Delfinów", "Molo", "Wydmy Bałtyku", "Sztorm"],
        ["Złote Wydmy", "Oaza", "Kaktusowy Szlak", "Kanion Słońca", "Burza Piaskowa", "Miraż", "Skorpion", "Piramida"],
        ["Leśna Ścieżka", "Polana", "Stary Dąb", "Wąwóz Paproci", "Bobrowa Tama", "Mglisty Bór", "Sowia Góra", "Puszcza"],
        ["Śnieżny Start", "Lodowa Tafla", "Bałwanek", "Przełęcz", "Zorza", "Lawina", "Szczyt Mrozu", "Królestwo Lodu"],
    ]

    private static func make(_ id: Int) -> TrackSpec {
        let index = id - 1
        let region = Region(rawValue: index / perRegion)!
        let difficulty = Double(index) / Double(count - 1)
        let name = names[region.rawValue][index % perRegion]
        // Gra dla dzieci: najwyżej 2 okrążenia, jezdnia zwęża się tylko trochę.
        let laps = 2
        let halfWidth = 9.5 - 0.7 * difficulty
        if id == 1 {
            return TrackSpec(id: 1, name: name, region: .city, points: TrackData.cityLoop,
                             halfWidth: TrackData.cityLoopHalfWidth, laps: 2, difficulty: 0)
        }
        // Szukamy (deterministycznie) pierwszego ziarna, które daje poprawną trasę.
        var attempt: UInt64 = 0
        while true {
            let points = generate(seed: UInt64(id) &* 7919 &+ attempt &* 104_729, difficulty: difficulty)
            let track = Track(points: points, halfWidth: halfWidth)
            if TrackValidator.problems(track).isEmpty {
                return TrackSpec(id: id, name: name, region: region, points: points,
                                 halfWidth: halfWidth, laps: laps, difficulty: difficulty)
            }
            attempt += 1
            precondition(attempt < 500, "generator nie znalazł poprawnej trasy \(id)")
        }
    }

    /// Pętla „gwiaździsta”: punkty po kolejnych kątach, promień zmienia się wokół średniej.
    /// Kąty rosną monotonicznie, więc łamana się nie przecina; resztę sprawdza `TrackValidator`.
    static func generate(seed: UInt64, difficulty: Double) -> [SIMD2<Double>] {
        let rng = SeededRandom(seed: seed)
        // Łagodnie: późniejsze trasy mają więcej zakrętów, ale nadal szerokie łuki.
        let count = 7 + Int((difficulty * 5).rounded()) + Int(rng.next() * 3)
        let baseRadius = 250 + rng.next() * 160
        let wobble = 0.1 + 0.2 * difficulty
        let stretch = 0.75 + rng.next() * 0.5 // owalność
        return (0..<count).map { i in
            let a = (Double(i) + (rng.next() - 0.5) * 0.5) / Double(count) * 2 * .pi
            let r = baseRadius * (1 + (rng.next() * 2 - 1) * wobble)
            return [cos(a) * r * stretch, sin(a) * r]
        }
    }
}

/// Reguły poprawnej trasy — używane przez generator i testy.
public enum TrackValidator {
    public static let minRadius = 32.0
    public static let lengthRange = 1000.0...3600.0

    public static func problems(_ track: Track) -> [String] {
        var out: [String] = []
        if !lengthRange.contains(track.length) { out.append("długość \(Int(track.length)) m") }
        var maxK = 0.0
        var s = 0.0
        var pts: [(Double, Double, Double)] = []
        while s < track.length {
            let p = track.sample(at: s)
            maxK = max(maxK, abs(p.curvature))
            pts.append((s, p.x, p.z))
            s += 8
        }
        if 1 / maxK < minRadius { out.append("zakręt o promieniu \(Int(1 / maxK)) m") }
        // Odległe po trasie fragmenty nie mogą się do siebie zbliżać (zachodzące bandy, przecięcia).
        let clearance = 2 * (track.halfWidth + 1.4) + 12
        outer: for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                let along = abs(wrapDelta(pts[i].0, pts[j].0, track.length))
                guard along > 120 else { continue }
                let dx = pts[i].1 - pts[j].1, dz = pts[i].2 - pts[j].2
                if dx * dx + dz * dz < clearance * clearance {
                    out.append("trasa zbliża się do siebie przy s=\(Int(pts[i].0)) i s=\(Int(pts[j].0))")
                    break outer
                }
            }
        }
        return out
    }
}
