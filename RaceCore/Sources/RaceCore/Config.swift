// Wszystkie liczby do strojenia rozgrywki w jednym miejscu. Jednostki: metry, sekundy, radiany.

public enum RaceConfig {
    public static let laps = 2
    public static let opponents = 5
    public static let countdown = 3.0
    /// Odstęp między rzędami na starcie.
    public static let gridSpacing = 9.0
    /// Ile sekund po mecie gracza pokazać wyniki.
    public static let finishDelay = 3.0
}

public enum Physics {
    public static let carLength = 4.4
    public static let carWidth = 2.0
    public static let brakeDecel = 28.0
    public static let nitroAccelFactor = 1.8
    /// Jak szybko auto zwalnia do prędkości maksymalnej po wygaśnięciu nitro.
    public static let overspeedDecay = 0.7
    public static let driftMinSpeed = 18.0
    public static let driftSpeedFactor = 0.94
    /// Drift skręca ostrzej niż zwykła jazda.
    public static let driftSteerFactor = 1.7
    /// Kąt, o jaki tył auta wychodzi w drifcie (wizualny poślizg).
    public static let driftSlideAngle = 0.5
    /// Asystent: bez skrętu auto samo ustawia się wzdłuż trasy.
    public static let steerAssist = 1.2
    /// Maksymalny kąt jazdy względem osi trasy — nie da się jechać w poprzek.
    public static let maxAlpha = 0.6
    /// Prędkość poprzeczna (m/s), przy której uderzenie w bandę rozbija auto.
    public static let wreckImpact = 32.0
    public static let wallFriction = 0.5
    public static let wreckTime = 2.0
    public static let driftNitroGain = 0.22
    public static let takedownNitro = 0.3
    public static let nearMissNitro = 0.08
    /// Na tyle blisko bokiem przy wyprzedzaniu liczy się „na włos”.
    public static let nearMissGap = 1.5
    /// Prędkość zbliżania bokiem (m/s), która spycha rywala w rozbicie.
    public static let sideSlamSpeed = 6.0
    /// Różnica prędkości przy uderzeniu w tył, która rozbija auto z przodu.
    public static let rearTakedownDelta = 12.0
    /// Rywale nie driftują, więc nitro rośnie im samo.
    public static let aiPassiveNitro = 0.04
}

public enum NitroConfig {
    public static let startGauge = 0.35
    public static let minToActivate = 0.15
    public static let burnTime = 2.0
    /// Ostatnie sekundy spalania, w których ponowne wciśnięcie daje „perfect nitro”.
    public static let perfectWindow = 0.45
    public static let drainPerSec = 0.22
    /// Dwa wciśnięcia w tym czasie = fala uderzeniowa (shockwave).
    public static let doubleTapWindow = 0.28
    public static let shockwaveMinGauge = 0.5
    public static let shockwaveTime = 3.0

    public static func boost(_ mode: NitroMode) -> Double {
        switch mode {
        case .off: 1
        case .normal: 1.25
        case .perfect: 1.4
        case .shockwave: 1.6
        }
    }
}
