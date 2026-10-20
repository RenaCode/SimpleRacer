import RaceCore

/// Dostęp do pełnej wersji gry: wszystkie auta i wszystkie trasy.
///
/// Na razie pełna wersja jest odblokowana w każdej konfiguracji (Debug, Family, Release) — do testów,
/// dopóki gra nie idzie do App Store. Przed wydaniem: subskrypcja StoreKit z Chmurą rodzinną
/// (Family Sharing — jedna subskrypcja na całą rodzinę), sprawdzana przez `Transaction.currentEntitlements`;
/// wtedy `isUnlocked` czyta stan subskrypcji zamiast stałej, a bez niej zostaje darmowa część gry.
enum FullVersion {
    static let isUnlocked = true

    /// Przekazuje stan do zasad kampanii (RaceCore). Wołane na starcie aplikacji.
    static func apply() { Campaign.fullVersion = isUnlocked }
}
