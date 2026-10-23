/// Poziom trudności z ustawień: jak szybcy są rywale. Nagrody i progi tras się nie zmieniają —
/// trudność decyduje tylko o tym, jak łatwo wygrać.
public enum Difficulty: String, Codable, CaseIterable, Sendable {
    case veryEasy, easy, normal

    /// Domyślny dla nowego gracza i zapisów sprzed tej opcji: gra dla małych dzieci.
    public static let standard: Difficulty = .veryEasy

    public var name: String {
        switch self {
        case .veryEasy: "Bardzo łatwy"
        case .easy: "Łatwy"
        case .normal: "Normalny"
        }
    }

    /// O ile rywale są słabsi od mocy wymaganej na trasie.
    public var rivalHandicap: Int {
        switch self {
        case .veryEasy: 60
        case .easy: 25
        case .normal: 0
        }
    }

    /// Przesunięcie umiejętności rywali (`Campaign.aiSkill`).
    public var skillOffset: Double {
        switch self {
        case .veryEasy: -0.1
        case .easy: 0
        case .normal: 0.06
        }
    }

    /// Gumka: zakres mnożnika prędkości rywala zależnie od odległości do gracza (dół — rywal daleko
    /// z przodu, góra — daleko z tyłu).
    public var rubberBand: ClosedRange<Double> {
        switch self {
        case .veryEasy: 0.78...1.0
        case .easy: 0.85...1.05
        case .normal: 0.9...1.08
        }
    }
}
