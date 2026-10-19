import AVFoundation
import Foundation

/// Dźwięk gry: zapętlona muzyka (CC0, App/Audio/*.m4a), silnik syntezowany na żywo i krótkie efekty
/// generowane w kodzie. Sesja `.ambient`: gra miesza się z innymi dźwiękami i słucha wyciszenia urządzenia.
@MainActor
final class AudioManager {
    static let shared = AudioManager()

    enum Track { case menu, race }
    enum Effect: CaseIterable { case beep, go, pickup, nitro, crash, takedown }

    var musicOn = true { didSet { applyVolumes() } }
    var soundOn = true { didSet { applyVolumes() } }

    private let engine = AVAudioEngine()
    private let music = AVAudioPlayerNode()
    private var sfx: [AVAudioPlayerNode] = []
    private var nextSfx = 0
    private var buffers: [Effect: AVAudioPCMBuffer] = [:]
    private var musicBuffers: [String: AVAudioPCMBuffer] = [:]
    private var currentTrack: Track?
    private var raceTrackIndex = 0
    private let synth = EngineSynth()
    private lazy var engineNode: AVAudioSourceNode = {
        let synth = self.synth
        return AVAudioSourceNode { _, _, frameCount, bufferList -> OSStatus in
            synth.render(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(bufferList))
            return noErr
        }
    }()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var started = false

    private static let musicVolume: Float = 0.45
    private static let sfxVolume: Float = 0.7

    private init() {
        engine.attach(music)
        engine.connect(music, to: engine.mainMixerNode, format: format)
        engine.attach(engineNode)
        engine.connect(engineNode, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        for _ in 0..<5 {
            let n = AVAudioPlayerNode()
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: format)
            sfx.append(n)
        }
        for e in Effect.allCases { buffers[e] = Self.synthesize(e, format: format) }

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

    /// Dźwięk silnika: `speed` 0…1+ (względem prędkości maksymalnej), `nitro` podbija ton i głośność.
    func setEngine(speed: Double, nitro: Bool, running: Bool) {
        synth.target(pitch: 55 + 140 * min(1.4, max(0, speed)) + (nitro ? 25 : 0),
                     volume: running && soundOn ? (nitro ? 0.22 : 0.15) : 0)
    }

    private func applyVolumes() {
        music.volume = musicOn ? Self.musicVolume : 0
        for n in sfx { n.volume = Self.sfxVolume }
        if !soundOn { synth.target(pitch: 55, volume: 0) }
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
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for ch in 0..<Int(format.channelCount) {
            let dst = buffer.floatChannelData![ch]
            for i in 0..<samples.count { dst[i] = samples[i] * 0.5 }
        }
        return buffer
    }
}

/// Syntezator silnika na wątku audio: piłokształtny ton z harmoniczną, wygładzane zmiany wysokości i głośności.
/// Wartości docelowe ustawia wątek główny; drobne wyścigi przy odczycie Float są tu nieszkodliwe.
final class EngineSynth: @unchecked Sendable {
    private var pitch = 55.0, volume = 0.0
    private var targetPitch = 55.0, targetVolume = 0.0
    private var phase = 0.0, phase2 = 0.0

    func target(pitch: Double, volume: Double) {
        targetPitch = pitch
        targetVolume = volume
    }

    func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        let sr = 44_100.0
        for i in 0..<frames {
            pitch += (targetPitch - pitch) * 0.0008
            volume += (targetVolume - volume) * 0.0005
            phase += pitch / sr
            phase2 += pitch * 2.01 / sr
            if phase >= 1 { phase -= 1 }
            if phase2 >= 1 { phase2 -= 1 }
            let saw = 2 * phase - 1
            let saw2 = 2 * phase2 - 1
            let v = Float((saw * 0.7 + saw2 * 0.3) * volume)
            for b in buffers {
                b.mData?.assumingMemoryBound(to: Float.self)[i] = v
            }
        }
    }
}

/// Diagnostyka tylko w buildzie Debug (widoczna w konsoli Xcode / `simctl launch --console-pty`).
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
