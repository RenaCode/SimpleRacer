import AVFoundation
import Foundation

/// Dźwięk gry: zapętlona muzyka (CC0, App/Audio/*.m4a), silnik/opony/wiatr/nitro syntezowane na żywo
/// (`EngineSynth`) i krótkie efekty generowane w kodzie. Sesja `.ambient`: gra miesza się z innymi
/// dźwiękami i słucha wyciszenia urządzenia.
@MainActor
final class AudioManager {
    static let shared = AudioManager()

    enum Track { case menu, race }
    enum Effect: CaseIterable { case beep, go, pickup, nitro, crash, takedown }
    private enum ImpactSound: CaseIterable { case hit, scrape }

    var musicOn = true { didSet { applyVolumes() } }
    var soundOn = true { didSet { applyVolumes() } }

    private let engine = AVAudioEngine()
    private let music = AVAudioPlayerNode()
    private var sfx: [AVAudioPlayerNode] = []
    private var nextSfx = 0
    private var buffers: [Effect: AVAudioPCMBuffer] = [:]
    private var impactNodes: [ImpactSound: AVAudioPlayerNode] = [:]
    private var impactBuffers: [ImpactSound: AVAudioPCMBuffer] = [:]
    private var lastImpact = 0.0
    private var musicBuffers: [String: AVAudioPCMBuffer] = [:]
    private var currentTrack: Track?
    private var raceTrackIndex = 0
    private static let synthRate = 44_100.0
    private let synth = EngineSynth(sampleRate: AudioManager.synthRate)
    private lazy var engineNode: AVAudioSourceNode = {
        let synth = self.synth
        return AVAudioSourceNode { _, _, frameCount, bufferList -> OSStatus in
            // Wątek audio: bez alokacji i blokad. Synteza mono do pierwszego kanału, reszta to kopia.
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            synth.render(frames: Int(frameCount), into: first)
            for b in buffers.dropFirst() {
                b.mData?.assumingMemoryBound(to: Float.self).update(from: first, count: Int(frameCount))
            }
            return noErr
        }
    }()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var started = false
    private var lastSpeed = 0.0
    private var lastSpeedTime: Double?
    private var throttle = 1.0

    private static let musicVolume: Float = 0.45
    private static let sfxVolume: Float = 0.7

    private init() {
        engine.attach(music)
        engine.connect(music, to: engine.mainMixerNode, format: format)
        engine.attach(engineNode)
        engine.connect(engineNode, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: Self.synthRate, channels: 1))
        for _ in 0..<5 {
            let n = AVAudioPlayerNode()
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: format)
            sfx.append(n)
        }
        for e in Effect.allCases { buffers[e] = Self.synthesize(e, format: format) }
        // Uderzenia w bandę mają własne węzły: głośność zależy od siły, a otarcie może się powtarzać.
        for i in ImpactSound.allCases {
            let n = AVAudioPlayerNode()
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: format)
            impactNodes[i] = n
            impactBuffers[i] = Self.synthesizeImpact(i, format: format)
        }

        // Przerwania (telefon, FaceTime, Siri) i zmiany wyjścia audio zatrzymują silnik — wznawiamy go.
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if type == .ended { MainActor.assumeIsolated { self?.restart() } }
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    /// Uruchamia dźwięk; bezpieczne do wołania wielokrotnie (np. po powrocie aplikacji na pierwszy plan).
    func start() {
        guard !started else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            engine.prepare()
            try engine.start()
            started = true
            debugLog("audio: silnik uruchomiony")
            applyVolumes()
            if let t = currentTrack { currentTrack = nil; play(t) }
        } catch {
            // Bez dźwięku gra działa dalej — brak audio nie może jej zatrzymać.
            debugLog("audio: start nieudany: \(error)")
            started = false
        }
    }

    func stop() {
        engine.pause()
        started = false
    }

    private func restart() {
        started = false
        start()
    }

    func play(_ track: Track) {
        let file: String
        switch track {
        case .menu:
            if currentTrack == .menu { return }
            file = "menu"
        case .race:
            // Kolejne wyścigi na zmianę: „Stage 1”, „Stage 2”.
            raceTrackIndex = (raceTrackIndex % 2) + 1
            file = "race-\(raceTrackIndex)"
        }
        currentTrack = track
        guard started, let buffer = musicBuffer(file) else {
            debugLog("audio: brak muzyki \(file) (started=\(started))")
            return
        }
        debugLog("audio: gra \(file), \(String(format: "%.1f", Double(buffer.frameLength) / buffer.format.sampleRate)) s")
        music.stop()
        music.scheduleBuffer(buffer, at: nil, options: [.loops])
        music.play()
    }

    private func musicBuffer(_ name: String) -> AVAudioPCMBuffer? {
        if let b = musicBuffers[name] { return b }
        guard let url = Bundle.main.url(forResource: name, withExtension: "m4a"),
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return nil }
        // Wszystkie bufory idą przez ten sam format węzła (44,1 kHz stereo); muzyka ma ten sam.
        guard buffer.format == format else {
            debugLog("audio: format \(name) \(buffer.format) ≠ \(format)")
            return nil
        }
        musicBuffers[name] = buffer
        return buffer
    }

    func play(_ effect: Effect) {
        guard started, soundOn, let b = buffers[effect] else { return }
        let node = sfx[nextSfx]
        nextSfx = (nextSfx + 1) % sfx.count
        node.stop()
        node.scheduleBuffer(b, at: nil)
        node.play()
    }

    /// Dźwięk jazdy, wołany co klatkę. `speed` 0…1+ (względem prędkości maksymalnej), `nitro` podbija
    /// silnik i dodaje syk, `running` = false gasi silnik (wrak, pauza). `slip` 0…1 to kąt poślizgu
    /// względem pełnego driftu (`abs(slide) / Physics.driftSlideAngle`), `drifting` włącza pisk od razu,
    /// zanim auto zdąży się obrócić. Gaz/hamowanie silnikiem wynika z pochodnej prędkości (auto przyspiesza
    /// samo): spadek prędkości to zamknięta przepustnica — matowa barwa i strzały z wydechu.
    func setEngine(speed: Double, nitro: Bool, running: Bool, slip: Double = 0, drifting: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastSpeedTime, now - last > 0.001, now - last < 0.5 {
            let dv = (speed - lastSpeed) / (now - last)
            if dv < -0.05 { throttle = 0 } else if dv > -0.01 { throttle = 1 }
        } else {
            throttle = 1
        }
        lastSpeed = speed
        lastSpeedTime = now
        synth.set(speed: speed, nitro: nitro, running: running && soundOn,
                  slip: max(slip, drifting ? 0.35 : 0), throttle: throttle)
    }

    /// Uderzenie w bandę albo otarcie o nią. `intensity` 0…1: poniżej ~0,3 słychać głównie zgrzyt
    /// metalu (otarcie), wyżej dochodzi tąpnięcie o głośności rosnącej z siłą. Kolejne wywołania w ciągu
    /// 70 ms są pomijane, więc można wołać co klatkę podczas ciągłego tarcia o bandę.
    func impact(intensity: Double) {
        guard started, soundOn, intensity.isFinite, intensity > 0.02 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastImpact >= 0.07 else { return }
        lastImpact = now
        let force = min(1, intensity)
        trigger(.scrape, volume: Self.sfxVolume * Float(0.35 + 0.65 * force))
        if force >= 0.3 {
            trigger(.hit, volume: Self.sfxVolume * Float((force - 0.3) / 0.7 * 0.8 + 0.2))
        }
    }

    private func trigger(_ sound: ImpactSound, volume: Float) {
        guard let node = impactNodes[sound], let buffer = impactBuffers[sound] else { return }
        node.stop()
        node.volume = volume
        node.scheduleBuffer(buffer, at: nil)
        node.play()
    }

    private func applyVolumes() {
        music.volume = musicOn ? Self.musicVolume : 0
        for n in sfx { n.volume = Self.sfxVolume }
        synth.setMaster(soundOn ? 1 : 0)
        if !soundOn {
            synth.set(speed: 0, nitro: false, running: false, slip: 0, throttle: 1)
            for n in impactNodes.values { n.stop() }
        }
    }

    // MARK: - Synteza efektów

    private static func synthesize(_ e: Effect, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        func tone(_ parts: [(freq: Double, dur: Double)], wave: (Double) -> Double, decay: Double) -> [Float] {
            var out: [Float] = []
            for p in parts {
                let n = Int(p.dur * sr)
                for i in 0..<n {
                    let t = Double(i) / sr
                    let env = min(1, t * 200) * exp(-t * decay)
                    out.append(Float(wave(2 * .pi * p.freq * t) * env))
                }
            }
            return out
        }
        let sine: (Double) -> Double = { sin($0) }
        let square: (Double) -> Double = { sin($0) >= 0 ? 0.6 : -0.6 }
        var rng = SystemRandomNumberGenerator()
        func noise(_ dur: Double, decay: Double, rising: Bool) -> [Float] {
            var out: [Float] = []
            var lp = 0.0
            let n = Int(dur * sr)
            for i in 0..<n {
                let t = Double(i) / sr
                let cutoff = rising ? 0.05 + 0.5 * t / dur : 0.35
                lp += cutoff * (Double.random(in: -1...1, using: &rng) - lp)
                let env = min(1, t * 60) * exp(-t * decay)
                out.append(Float(lp * env * 1.6))
            }
            return out
        }
        let samples: [Float]
        switch e {
        case .beep: samples = tone([(660, 0.16)], wave: square, decay: 10)
        case .go: samples = tone([(990, 0.45)], wave: square, decay: 4)
        case .pickup: samples = tone([(784, 0.07), (1047, 0.07), (1319, 0.14)], wave: sine, decay: 6)
        case .nitro: samples = noise(0.6, decay: 3, rising: true)
        case .crash:
            let thump = tone([(70, 0.35)], wave: sine, decay: 9)
            let hiss = noise(0.35, decay: 9, rising: false)
            samples = zip(thump, hiss).map { $0 + $1 * 0.7 }
        case .takedown:
            samples = tone([(523, 0.08), (659, 0.08), (784, 0.08), (1047, 0.2)], wave: square, decay: 5)
        }
        return buffer(samples, gain: 0.5, format: format)
    }

    /// Uderzenie: tąpnięcie (sinus 90→45 Hz) + dzwonienie blachy (nieharmoniczne, lekko rozstrojone pary
    /// dają dudnienie) + krótki szum. Otarcie: szum pasmowy ~2–5 kHz z nieregularnym „zgrzytaniem”
    /// i dwoma cienkimi tonami blachy.
    private static func synthesizeImpact(_ sound: ImpactSound, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        var rng = SystemRandomNumberGenerator()
        var samples: [Float] = []
        switch sound {
        case .hit:
            let n = Int(0.45 * sr)
            samples.reserveCapacity(n)
            var phase = 0.0
            var lpFast = 0.0, lpSlow = 0.0
            let partials: [(Double, Double)] = [(1190, 1.0), (1196, 0.7), (2370, 0.6), (2381, 0.4), (3650, 0.35), (5210, 0.2)]
            for i in 0..<n {
                let t = Double(i) / sr
                phase += (45 + 45 * exp(-t * 14)) / sr
                let thump = sin(2 * .pi * phase) * exp(-t * 11) * 0.8
                var metal = 0.0
                for (f, a) in partials { metal += sin(2 * .pi * f * t) * a }
                metal *= exp(-t * 9) * 0.16
                let w = Double.random(in: -1...1, using: &rng)
                lpFast += 0.45 * (w - lpFast)
                lpSlow += 0.08 * (w - lpSlow)
                let crack = (lpFast - lpSlow) * exp(-t * 28) * 1.2
                samples.append(Float((thump + metal + crack) * min(1, t * 400)))
            }
        case .scrape:
            let n = Int(0.32 * sr)
            samples.reserveCapacity(n)
            var lpFast = 0.0, lpSlow = 0.0, grind = 0.0
            let jitter1 = Double.random(in: 0.97...1.03, using: &rng), jitter2 = Double.random(in: 0.97...1.03, using: &rng)
            for i in 0..<n {
                let t = Double(i) / sr
                let w = Double.random(in: -1...1, using: &rng)
                lpFast += 0.5 * (w - lpFast)
                lpSlow += 0.15 * (w - lpSlow)
                // Nieregularne zgrzytanie: wolno błądząca modulacja (~40 Hz) przechodzi przez próg.
                grind += 0.006 * (w - grind)
                let gate = 0.45 + 0.55 * (grind > 0 ? 1.0 : 0.25)
                let tones = sin(2 * .pi * 3100 * jitter1 * t) * 0.12 + sin(2 * .pi * 4700 * jitter2 * t) * 0.07
                let env = min(1, t * 250) * exp(-t * 9)
                samples.append(Float(((lpFast - lpSlow) * 2.4 * gate + tones * gate) * env))
            }
        }
        return buffer(samples, gain: 0.5, format: format)
    }

    private static func buffer(_ samples: [Float], gain: Float, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for ch in 0..<Int(format.channelCount) {
            let dst = buffer.floatChannelData![ch]
            for i in 0..<samples.count { dst[i] = samples[i] * gain }
        }
        return buffer
    }
}

/// Diagnostyka tylko w buildzie Debug (widoczna w konsoli Xcode / `simctl launch --console-pty`).
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG || FAMILY
    print(String(format: "[%.2f s] ", ProcessInfo.processInfo.systemUptime - appStartUptime) + message())
    #endif
}

/// Chwila startu procesu (do pomiaru czasów ładowania w logach Debug).
let appStartUptime = ProcessInfo.processInfo.systemUptime
