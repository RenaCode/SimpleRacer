public struct CarShape: Sendable {
    public var length: Double
    public var width: Double
    public var height: Double
    /// Długość kabiny jako ułamek długości auta.
    public var cabinLength: Double
    /// Przesunięcie kabiny wzdłuż auta (m, ujemne = do tyłu).
    public var cabinOffset: Double
    public var spoiler: Bool
}

/// Model 3D auta z pliku OBJ (App/Models/Cars) i pole palety tekstury, które jest lakierem.
/// Pole palety: tekstura 512×512 podzielona na 8 kolumn × 4 wiersze; wiersz 0 to góra obrazu.
public struct CarModelRef: Sendable {
    public var file: String
    public var paintRow: Int
    public var paintColumn: Int
}

public struct CarDef: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    /// m/s
    public var topSpeed: Double
    /// m/s²
    public var accel: Double
    /// Maksymalna szybkość obrotu, rad/s.
    public var handling: Double
    /// Mnożnik siły nitro.
    public var nitroPower: Double
    public var shape: CarShape
    /// Gotowy model; nil = nadwozie generowane z `shape`.
    public var model: CarModelRef? = nil
}

public enum CarCatalog {
    public static let all: [CarDef] = [
        CarDef(
            id: "strzala", name: "Strzała", description: "Wszechstronna — dobra na każdą trasę.",
            topSpeed: 75, accel: 14, handling: 1.6, nitroPower: 1.0,
            shape: CarShape(length: 4.4, width: 2.0, height: 1.2, cabinLength: 0.42, cabinOffset: -0.2, spoiler: false),
            model: CarModelRef(file: "sedan-sports", paintRow: 1, paintColumn: 6)
        ),
        CarDef(
            id: "grom", name: "Grom", description: "Najszybsza na prostych, ciężka w zakrętach.",
            topSpeed: 82, accel: 11, handling: 1.35, nitroPower: 1.15,
            shape: CarShape(length: 4.7, width: 2.05, height: 1.05, cabinLength: 0.34, cabinOffset: -0.45, spoiler: true),
            model: CarModelRef(file: "race-future", paintRow: 1, paintColumn: 7)
        ),
        CarDef(
            id: "zwinny", name: "Zwinny", description: "Mocno przyspiesza i świetnie driftuje.",
            topSpeed: 70, accel: 16, handling: 1.9, nitroPower: 0.95,
            shape: CarShape(length: 4.0, width: 1.9, height: 1.3, cabinLength: 0.5, cabinOffset: -0.1, spoiler: false),
            model: CarModelRef(file: "hatchback-sports", paintRow: 1, paintColumn: 3)
        ),
    ]

    /// Zakresy do pasków statystyk w garażu.
    public static let topSpeedRange = 60.0...90.0
    public static let accelRange = 8.0...18.0
    public static let handlingRange = 1.0...2.2
    public static let nitroRange = 0.8...1.3

    /// Gotowe kolory lakieru (hex). W garażu jest też dowolny kolor z próbnika.
    public static let colors = ["#E63946", "#F77F00", "#FFD60A", "#2A9D8F", "#3A86FF", "#8338EC", "#F1F1F1", "#1B1B1E"]

    public static func car(id: String) -> CarDef { all.first { $0.id == id } ?? all[0] }
}
