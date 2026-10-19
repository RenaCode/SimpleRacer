import Foundation

/// Syntezator dźwięku jazdy liczony w callbacku audio (`AVAudioSourceNode`), bez próbek z plików:
/// - silnik V8 z wirtualną skrzynią 6 biegów: obroty wynikają z prędkości i biegu, zmiana biegu to
///   ~80 ms „cięcia” gazu i opadnięcie obrotów; barwa to impulsy zapłonów (RPM/60 × cylindry/2)
///   o losowanej sile, pobudzające rezonatory wydechu, plus piła i pomruk pół-rzędu, szum spalania,
///   filtr dolnoprzepustowy zależny od obciążenia (gaz/hamowanie) i strzały z wydechu na hamowaniu silnikiem;
/// - pisk opon: szum pasmowy ~1–3 kHz z wibracją i tonem, głośność z kąta poślizgu;
/// - wiatr: szum różowy, głośność ~ prędkość²;
/// - nitro: podbicie silnika i syk z przemiatanym filtrem.
///
/// Cały stan ma stały rozmiar — `render` nie alokuje, nie blokuje i nie woła w system (własny PRNG).
/// Wartości docelowe ustawia wątek główny; zapisy 64-bitowe są na arm64 atomowe, a drobne wyścigi
/// dają co najwyżej jedną klatkę opóźnienia. Plik nie zależy od AVFoundation — kompiluje się także na
/// macOS do odsłuchu offline (`tools/audition-engine.swift`).
final class EngineSynth: @unchecked Sendable {
    // MARK: - Strojenie

    /// Liczba cylindrów: częstotliwość zapłonów = RPM/60 × cylindry/2.
    static let cylinders = 8.0
    static let idleRPM = 900.0
    static let redlineRPM = 7400.0
    /// Prędkość (względem maksymalnej, 1 = `topSpeed`) przy czerwonym polu na kolejnych biegach.
    static let gearTops: [Double] = [0.14, 0.25, 0.38, 0.54, 0.74, 1.0]
    /// Ile sekund trwa cięcie gazu przy zmianie biegu.
    static let shiftCut = 0.08
    /// Poniżej jakiego ułamka czerwonego pola skrzynia redukuje bieg.
    static let downshiftAt = 0.40
    private static let block = 64

    // MARK: - Wejścia (wątek główny → audio)

    private var inSpeed = 0.0
    private var inNitro = 0.0
    private var inRunning = 0.0
    private var inSlip = 0.0
    private var inThrottle = 1.0
    private var inMaster = 1.0

    /// `speed` 0…1,4 względem prędkości maksymalnej, `slip` 0…1 (kąt poślizgu / pełny drift),
    /// `throttle` 0…1 (1 = gaz do dechy, 0 = hamowanie silnikiem).
    func set(speed: Double, nitro: Bool, running: Bool, slip: Double, throttle: Double) {
        inSpeed = speed.isFinite ? max(0, min(1.4, speed)) : 0
        inNitro = nitro ? 1 : 0
        inRunning = running ? 1 : 0
        inSlip = slip.isFinite ? max(0, min(1, slip)) : 0
        inThrottle = throttle.isFinite ? max(0, min(1, throttle)) : 1
    }

    /// Głośność całości (0 = wyciszone); zmiana jest wygładzana, więc nie trzaska.
    func setMaster(_ value: Double) { inMaster = max(0, min(1, value)) }

    /// Aktualny bieg (1…6) — do diagnostyki i testów offline.
    private(set) var gear = 1

    // MARK: - Stan

    let sampleRate: Double
    private var rng: UInt32 = 0x9E37_79B9
    private var time = 0.0

    // Skrzynia i obroty
    private var gearIndex = 0
    private var shiftTimer = 0.0
    private var rpm = EngineSynth.idleRPM
    private var rpmTarget = EngineSynth.idleRPM
    private var rpmNorm = 0.0
    private var throttle = 1.0
    private var throttleTarget = 1.0
    private var cut = 1.0
    private var cutTarget = 1.0
    private var engineGain = 0.0
    private var engineGainTarget = 0.0
    private var master = 1.0
    private var nitroMix = 0.0
    private var idleWobble = 0.0

    // Generator silnika
    private var firePhase = 0.0
    private var halfPhase = 0.0
    private var excitation = 0.0
    private var burst = 0.0
    private var sawLevel = 0.0
    private var exhaust1 = Resonator(), exhaust2 = Resonator(), exhaust3 = Resonator(), tracking = Resonator()
    private var combustionBP = SVF()
    private var loadLP = SVF()
    private var fireInc = 0.0
    private var dcX1 = 0.0, dcY1 = 0.0
    private let dcCoef: Double

    // Pisk opon
    private var squealLevel = 0.0
    private var squealBP = SVF()
    private var squealTone = 0.0
    private var squealToneInc = 0.0
    private var squealWander = 0.0
    private var chatterPhase = 0.0

    // Wiatr
    private var pink0 = 0.0, pink1 = 0.0, pink2 = 0.0
    private var windLP = 0.0
    private var windX1 = 0.0, windY1 = 0.0
    private var windHPCoef = 0.0
    private var windCoef = 0.0
    private var windGain = 0.0
    private var windSpeed = 0.0

    // Nitro
    private var nitroCutoff = 500.0
    private var nitroLevel = 0.0
    private var nitroBP = SVF()

    // Współczynniki wygładzania (na próbkę)
    private let aRpm: Double, aThrottle: Double, aCut: Double, aGain: Double, aMaster: Double
    private let aSquealUp: Double, aSquealDown: Double, aNitroUp: Double, aNitroDown: Double

    init(sampleRate: Double = 44_100) {
        self.sampleRate = sampleRate
        func tau(_ seconds: Double) -> Double { 1 - exp(-1 / (seconds * sampleRate)) }
        aRpm = tau(0.065)
        aThrottle = tau(0.05)
        aCut = tau(0.004)
        aGain = tau(0.12)
        aMaster = tau(0.02)
        aSquealUp = tau(0.02)
        aSquealDown = tau(0.15)
        aNitroUp = tau(0.05)
        aNitroDown = tau(0.35)
        dcCoef = 1 - 2 * .pi * 25 / sampleRate
        windHPCoef = 1 - 2 * .pi * 70 / sampleRate
        // Rezonanse wydechu (stałe) — z nich bierze się „głębia” brzmienia.
        exhaust1.tune(frequency: 95, bandwidth: 35, sampleRate: sampleRate)
        exhaust2.tune(frequency: 185, bandwidth: 55, sampleRate: sampleRate)
        exhaust3.tune(frequency: 340, bandwidth: 90, sampleRate: sampleRate)
        tracking.tune(frequency: 120, bandwidth: 25, sampleRate: sampleRate)
        combustionBP.tune(cutoff: 1800, q: 1.2, sampleRate: sampleRate)
        loadLP.tune(cutoff: 1200, q: 0.8, sampleRate: sampleRate)
        squealBP.tune(cutoff: 1700, q: 12, sampleRate: sampleRate)
        nitroBP.tune(cutoff: 500, q: 1.3, sampleRate: sampleRate)
    }

    // MARK: - Render

    /// Wypełnia `out` (mono) `frames` próbkami. Wołane z wątku audio.
    func render(frames: Int, into out: UnsafeMutablePointer<Float>) {
        var done = 0
        while done < frames {
            let n = min(Self.block, frames - done)
            updateControls(blockFrames: n)
            renderBlock(frames: n, into: out + done)
            done += n
        }
    }

    /// Sterowanie w tempie bloku (co ≤64 próbki, ~1,5 ms): skrzynia biegów, cele dla wygładzania, filtry.
    private func updateControls(blockFrames n: Int) {
        let dt = Double(n) / sampleRate
        time += dt
        let speed = inSpeed
        let running = inRunning > 0.5
        let nitro = inNitro > 0.5
        let tops = Self.gearTops

        // Skrzynia: w górę na czerwonym polu, w dół poniżej `downshiftAt`; podczas cięcia nie zmieniamy ponownie.
        if shiftTimer > 0 {
            shiftTimer -= dt
        } else {
            let r = speed / tops[gearIndex]
            if r > 1.0 && gearIndex < tops.count - 1 {
                gearIndex += 1
                shiftTimer = Self.shiftCut
            } else if r < Self.downshiftAt && gearIndex > 0 {
                gearIndex -= 1
                shiftTimer = Self.shiftCut * 0.6
            }
        }
        gear = gearIndex + 1
        let shifting = shiftTimer > 0

        // Obroty: miękkie ograniczenie powyżej czerwonego pola (nitro na 6. biegu).
        var rn = speed / tops[gearIndex]
        if rn > 1 { rn = 1 + 0.12 * tanh((rn - 1) / 0.12) }
        rpmNorm = rn
        // Chybotanie na biegu jałowym.
        idleWobble += (random() * 0.6 - idleWobble) * 0.02
        let wobble = max(0, 1 - rn * 8) * (0.03 * sin(2 * .pi * 2.7 * time) + idleWobble * 0.02)
        rpmTarget = running ? (Self.idleRPM + rn * (Self.redlineRPM - Self.idleRPM)) * (1 + wobble) : Self.idleRPM * 0.6
        throttleTarget = shifting ? 0 : inThrottle
        cutTarget = shifting ? 0.12 : 1
        engineGainTarget = running ? 0.19 * (0.45 + 0.55 * rn) * (0.6 + 0.4 * throttle) * (nitro ? 1.3 : 1) : 0
        nitroMix += ((nitro ? 1 : 0) - nitroMix) * min(1, dt / 0.15)

        // Strzały z wydechu przy hamowaniu silnikiem na wysokich obrotach.
        if running && throttle < 0.35 && rn > 0.3 && random() < 0.018 * rn {
            let a = 2.2 + 1.5 * random()
            excitation += a
            burst += a * 1.5
        }

        // Filtry zależne od obrotów i obciążenia (współczynniki liczone raz na blok).
        let fireHz = rpm * Self.cylinders / 120
        fireInc = fireHz / sampleRate
        tracking.tune(frequency: min(2500, fireHz * 2), bandwidth: max(20, fireHz * 0.3), sampleRate: sampleRate)
        let cutoff = (420 + 2600 * throttle + 1900 * rn) * (1 + 0.25 * nitroMix)
        loadLP.tune(cutoff: min(9000, cutoff), q: 0.8, sampleRate: sampleRate)
        sawLevel = (0.10 + 0.32 * rn) * (0.45 + 0.55 * throttle)

        // Pisk opon: środek pasma „pływa” (LFO + błądzenie losowe).
        squealWander += (random() * 2 - 1 - squealWander) * 0.03
        let squealHz = 1700 * (1 + 0.10 * sin(2 * .pi * 6.5 * time) + 0.12 * squealWander)
        squealBP.tune(cutoff: squealHz, q: 12, sampleRate: sampleRate)
        squealToneInc = squealHz * 0.78 / sampleRate

        // Wiatr: głośność ~ prędkość², jaśniejszy przy większej prędkości.
        windSpeed += (speed - windSpeed) * min(1, dt / 0.2)
        let ws = min(1.3, windSpeed)
        windGain = 0.22 * ws * ws
        windCoef = 1 - exp(-2 * .pi * (300 + 2200 * ws) / sampleRate)

        // Nitro: przemiatany szum (whoosh) przy włączeniu, potem cichy syk.
        if nitro {
            nitroCutoff += (3200 - nitroCutoff) * min(1, dt / 0.25)
        } else {
            nitroCutoff = 500
        }
        nitroBP.tune(cutoff: nitroCutoff, q: 1.3, sampleRate: sampleRate)
    }

    private func renderBlock(frames n: Int, into out: UnsafeMutablePointer<Float>) {
        let running = inRunning > 0.5
        let slip = inSlip
        let speed = inSpeed
        let squealTarget = running ? pow(slip, 1.3) * min(1, speed * 4) * 0.28 : 0
        let nitroTarget = inNitro > 0.5 && running ? 0.28 : 0
        let masterTarget = inMaster
        let drive = 1.2 + 1.3 * throttle + 1.2 * nitroMix
        let driveNorm = 0.9 / softClip(drive)
        let exhaustGain = 0.9 + 0.5 * throttle

        for i in 0..<n {
            // Wygładzanie parametrów na każdej próbce — bez skoków, więc bez trzasków.
            rpm += (rpmTarget - rpm) * aRpm
            throttle += (throttleTarget - throttle) * aThrottle
            cut += (cutTarget - cut) * aCut
            engineGain += (engineGainTarget - engineGain) * aGain
            master += (masterTarget - master) * aMaster
            squealLevel += (squealTarget - squealLevel) * (squealTarget > squealLevel ? aSquealUp : aSquealDown)
            nitroLevel += (nitroTarget - nitroLevel) * (nitroTarget > nitroLevel ? aNitroUp : aNitroDown)

            // Zapłony: jeden impuls na cylinder, siła losowana (większy rozrzut przy małym gazie).
            firePhase += fireInc
            if firePhase >= 1 {
                firePhase -= 1
                let spread = 0.15 + 0.35 * (1 - throttle)
                let amp = 1 + spread * (random() * 2 - 1)
                excitation += amp
                burst += amp
            }
            halfPhase += fireInc * 0.5
            if halfPhase >= 1 { halfPhase -= 1 }
            let exc = excitation
            excitation *= 0.55
            burst *= 0.985

            let white = random() * 2 - 1
            let exhaust = exhaust1.process(exc) + exhaust2.process(exc) * 0.7 + exhaust3.process(exc) * 0.5
                + tracking.process(exc) * 0.6
            let saw = polyBlepSaw(phase: firePhase, inc: fireInc)
            let rumble = sin(2 * .pi * halfPhase) * (0.3 - 0.15 * rpmNorm)
            let combustion = combustionBP.band(white * burst) * (0.25 + 0.45 * throttle)
            let raw = (exhaust * exhaustGain + saw * sawLevel + rumble + combustion) * 0.4
            // Impulsy wydechu są jednostronne — rezonatory przenoszą składową stałą; blokada DC (25 Hz)
            // zdejmuje offset, zanim trafi w przester (inaczej moduluje się na infradźwięki).
            let mix = raw - dcX1 + dcCoef * dcY1
            dcX1 = raw
            dcY1 = mix
            let engine = softClip(loadLP.low(mix) * drive) * driveNorm * cut * engineGain

            // Pisk opon: szum pasmowy + ton z wibracją, drżenie ~23 Hz.
            var squeal = 0.0
            if squealLevel > 0.0005 {
                squealTone += squealToneInc
                if squealTone >= 1 { squealTone -= 1 }
                chatterPhase += 23 / sampleRate
                if chatterPhase >= 1 { chatterPhase -= 1 }
                let chatter = 1 + 0.25 * sin(2 * .pi * chatterPhase)
                squeal = (squealBP.band(white) * 5 + sin(2 * .pi * squealTone) * 0.3) * chatter * squealLevel
            }

            // Wiatr: szum różowy (filtr Kelleta) przez filtr jednobiegunowy.
            pink0 = 0.99765 * pink0 + white * 0.0990460
            pink1 = 0.96300 * pink1 + white * 0.2965164
            pink2 = 0.57000 * pink2 + white * 1.0526913
            let pink = (pink0 + pink1 + pink2 + white * 0.1848) * 0.18
            windLP += (pink - windLP) * windCoef
            // Szum różowy ma dużo energii poniżej 20 Hz — górnoprzepustowy 70 Hz zostawia sam „szum powietrza”.
            let windHP = windLP - windX1 + windHPCoef * windY1
            windX1 = windLP
            windY1 = windHP
            let wind = windHP * windGain * 1.4

            // Nitro: syk z przemiatanym pasmem.
            var hiss = 0.0
            if nitroLevel > 0.0005 {
                hiss = nitroBP.band(white) * 1.4 * nitroLevel
            }

            out[i] = Float((engine + squeal + wind + hiss) * master)
        }
    }

    // MARK: - Narzędzia

    /// xorshift32 → [0, 1). Bez wywołań systemowych (bezpieczny na wątku audio).
    @inline(__always) private func random() -> Double {
        var x = rng
        x ^= x << 13
        x ^= x >> 17
        x ^= x << 5
        rng = x
        return Double(x) * (1.0 / 4_294_967_296.0)
    }

    /// Miękkie ograniczenie (wielomianowe przybliżenie tanh), |x| ≥ 3 → ±1.
    @inline(__always) private func softClip(_ x: Double) -> Double {
        if x >= 3 { return 1 }
        if x <= -3 { return -1 }
        return x * (27 + x * x) / (27 + 9 * x * x)
    }

    /// Piła z korekcją polyBLEP — bez aliasingu przy wysokich obrotach.
    @inline(__always) private func polyBlepSaw(phase: Double, inc: Double) -> Double {
        var v = 2 * phase - 1
        if phase < inc {
            let t = phase / inc
            v -= t + t - t * t - 1
        } else if phase > 1 - inc {
            let t = (phase - 1) / inc
            v -= t * t + t + t + 1
        }
        return v
    }
}

/// Rezonator dwubiegunowy; `g = sin ω` normalizuje odpowiedź impulsową do szczytu ≈ 1.
struct Resonator {
    private var a1 = 0.0, a2 = 0.0, g = 0.0
    private var y1 = 0.0, y2 = 0.0

    mutating func tune(frequency: Double, bandwidth: Double, sampleRate: Double) {
        let r = exp(-.pi * bandwidth / sampleRate)
        let w = 2 * .pi * frequency / sampleRate
        a1 = 2 * r * cos(w)
        a2 = -r * r
        g = sin(w)
    }

    @inline(__always) mutating func process(_ x: Double) -> Double {
        let y = g * x + a1 * y1 + a2 * y2
        y2 = y1
        y1 = y
        return y
    }
}

/// Filtr stanu (TPT, wg A. Simpera): wyjścia low/band z jednego przebiegu.
struct SVF {
    private var ic1 = 0.0, ic2 = 0.0
    private var a1 = 0.0, a2 = 0.0, a3 = 0.0, k = 1.0

    mutating func tune(cutoff: Double, q: Double, sampleRate: Double) {
        let g = tan(.pi * min(cutoff, sampleRate * 0.45) / sampleRate)
        k = 1 / q
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    @inline(__always) private mutating func step(_ x: Double) -> (low: Double, band: Double) {
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return (v2, v1)
    }

    @inline(__always) mutating func low(_ x: Double) -> Double { step(x).low }
    /// Pasmo znormalizowane (wzmocnienie 1 w rezonansie, niezależnie od Q).
    @inline(__always) mutating func band(_ x: Double) -> Double { k * step(x).band }
}
