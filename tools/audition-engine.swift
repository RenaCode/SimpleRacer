// Odsłuch silnika bez symulatora: renderuje scenariusz przejazdu do pliku WAV (44,1 kHz, mono, 16 bit)
// i mierzy koszt CPU. Nie dotyka głośników.
//
//   swiftc -O App/Audio/EngineSynth.swift tools/audition-engine.swift -o /tmp/audition
//   /tmp/audition out.wav            # scenariusz: 0→280 km/h ze zmianami biegów, drift, nitro, hamowanie
//   /tmp/audition --bench            # 60 s renderu, wypisuje czas i udział CPU
//
// Zdarzenia (zmiany biegów, drift, nitro) idą na stdout z czasem w sekundach — do analizy trzasków.
import Foundation

let sampleRate = 44_100.0
let args = CommandLine.arguments.dropFirst()

if args.first == "--bench" {
    let synth = EngineSynth(sampleRate: sampleRate)
    let frames = 512
    let buf = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer { buf.deallocate() }
    let seconds = 60.0
    let blocks = Int(seconds * sampleRate) / frames
    synth.set(speed: 0.6, nitro: true, running: true, slip: 0.7, throttle: 1)
    let t0 = Date()
    for b in 0..<blocks {
        if b % 50 == 0 { synth.set(speed: 0.2 + 0.8 * Double(b % 1000) / 1000, nitro: b % 400 < 100, running: true, slip: 0.5, throttle: 1) }
        synth.render(frames: frames, into: buf)
    }
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "render %.0f s audio w %.3f s → %.2f%% rdzenia (ten Mac)", seconds, dt, 100 * dt / seconds))
    exit(0)
}

if args.first == "--levels" {
    // Poziom RMS każdej warstwy osobno (warstwy sumują się w kwadraturze, więc odejmujemy silnik).
    func rms(speed: Double, nitro: Bool, running: Bool, slip: Double, throttle: Double) -> Double {
        let synth = EngineSynth(sampleRate: sampleRate)
        let frames = 441
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { buf.deallocate() }
        synth.set(speed: speed, nitro: nitro, running: running, slip: slip, throttle: throttle)
        var sum = 0.0, count = 0.0, peak = 0.0
        for b in 0..<400 { // 4 s, pierwsze 2 s to rozbieg wygładzania
            synth.render(frames: frames, into: buf)
            if b >= 200 { for i in 0..<frames { let v = Double(buf[i]); sum += v * v; count += 1; peak = max(peak, abs(v)) } }
        }
        return (sum / count).squareRoot()
    }
    func show(_ name: String, _ total: Double, minus: Double = 0) {
        let v = max(0, total * total - minus * minus).squareRoot()
        print(String(format: "%-34@ RMS %.3f (%.1f dBFS)", name, v, 20 * log10(max(v, 1e-9))))
    }
    let idle = rms(speed: 0, nitro: false, running: true, slip: 0, throttle: 1)
    show("silnik: bieg jałowy", idle)
    let e05 = rms(speed: 0.5, nitro: false, running: true, slip: 0, throttle: 1)
    let w05 = rms(speed: 0.5, nitro: false, running: false, slip: 0, throttle: 1)
    show("silnik: v=0,5 pełny gaz", e05, minus: w05)
    let e05off = rms(speed: 0.5, nitro: false, running: true, slip: 0, throttle: 0)
    show("silnik: v=0,5 bez gazu", e05off, minus: w05)
    let w1 = rms(speed: 1, nitro: false, running: false, slip: 0, throttle: 1)
    let e1 = rms(speed: 1, nitro: false, running: true, slip: 0, throttle: 1)
    show("silnik: v=1 pełny gaz", e1, minus: w1)
    let e1n = rms(speed: 1.3, nitro: true, running: true, slip: 0, throttle: 1)
    let w13 = rms(speed: 1.3, nitro: false, running: false, slip: 0, throttle: 1)
    show("silnik+syk: v=1,3 nitro", e1n, minus: w13)
    show("wiatr: v=0,5", w05)
    show("wiatr: v=1", w1)
    show("wiatr: v=1,3", w13)
    let sq = rms(speed: 0.5, nitro: false, running: true, slip: 1, throttle: 1)
    show("pisk: v=0,5 slip=1", sq, minus: e05)
    let sq5 = rms(speed: 0.5, nitro: false, running: true, slip: 0.5, throttle: 1)
    show("pisk: v=0,5 slip=0,5", sq5, minus: e05)
    exit(0)
}

guard let outPath = args.first else {
    FileHandle.standardError.write("użycie: audition <plik.wav> | --bench\n".data(using: .utf8)!)
    exit(2)
}

// Model jazdy jak w RaceCore.Car: auto przyspiesza samo; topSpeed 75 m/s (270 km/h), accel 14 m/s².
let topSpeed = 75.0, accel = 14.0
var speed = 0.0
func kmh(_ v: Double) -> Double { v * 3.6 }

struct Phase { let until: Double; let running: Bool; let drive: Double; let drift: Bool; let nitro: Bool; let name: String }
// drive: >0 gaz (mnożnik przyspieszenia), <0 hamowanie (m/s²), 0 = koło wolne.
let phases: [Phase] = [
    Phase(until: 2.0, running: true, drive: 0, drift: false, nitro: false, name: "bieg jałowy"),
    Phase(until: 12.0, running: true, drive: 1, drift: false, nitro: false, name: "rozpędzanie"),
    Phase(until: 15.0, running: true, drive: 1, drift: true, nitro: false, name: "drift"),
    Phase(until: 17.0, running: true, drive: 1, drift: false, nitro: false, name: "prosta"),
    Phase(until: 21.0, running: true, drive: 1, drift: false, nitro: true, name: "nitro → 280 km/h"),
    Phase(until: 23.0, running: true, drive: 1, drift: false, nitro: false, name: "po nitro"),
    Phase(until: 30.0, running: true, drive: -9, drift: false, nitro: false, name: "hamowanie silnikiem"),
    Phase(until: 34.0, running: true, drive: 1, drift: false, nitro: false, name: "znów gaz"),
    Phase(until: 36.0, running: false, drive: 0, drift: false, nitro: false, name: "silnik stoi (wrak)"),
]

let synth = EngineSynth(sampleRate: sampleRate)
let total = phases.last!.until
let chunk = 441 // 10 ms — nietypowa długość callbacku, sprawdza łączenie bloków
var samples = [Float](repeating: 0, count: Int(total * sampleRate))
var slide = 0.0
var lastGear = synth.gear
var lastSpeed = 0.0
var throttle = 1.0
var phaseIndex = 0
var t = 0.0
var frame = 0
print(String(format: "%6.2f s  %@", 0.0, phases[0].name))
samples.withUnsafeMutableBufferPointer { out in
    while frame < out.count {
        let n = min(chunk, out.count - frame)
        let dt = Double(n) / sampleRate
        if t >= phases[phaseIndex].until, phaseIndex < phases.count - 1 {
            phaseIndex += 1
            print(String(format: "%6.2f s  %@ (%.0f km/h)", t, phases[phaseIndex].name, kmh(speed)))
        }
        let p = phases[phaseIndex]
        // Fizyka jak w Car.step: drift obniża prędkość maksymalną, nitro ją podnosi.
        let top = topSpeed * (p.nitro ? 1.3 : 1) * (p.drift ? 0.94 : 1)
        if p.drive > 0 {
            let a = accel * p.drive * (p.nitro ? 1.6 : 1)
            speed = min(top, speed + a * dt * (1 - 0.6 * speed / top))
        } else if p.drive < 0 {
            speed = max(0, speed + p.drive * dt)
        }
        slide += ((p.drift ? 0.5 : 0) - slide) * min(1, dt * (p.drift ? 6 : 8))
        // Gaz tak, jak liczy go AudioManager: z pochodnej prędkości.
        let dv = (speed - lastSpeed) / topSpeed / dt
        lastSpeed = speed
        if dv < -0.05 { throttle = 0 } else if dv > -0.01 { throttle = 1 }
        synth.set(speed: speed / topSpeed, nitro: p.nitro, running: p.running,
                  slip: max(abs(slide) / 0.5, p.drift ? 0.35 : 0), throttle: throttle)
        synth.render(frames: n, into: out.baseAddress! + frame)
        if synth.gear != lastGear {
            print(String(format: "%6.2f s  bieg %d → %d (%.0f km/h)", t, lastGear, synth.gear, kmh(speed)))
            lastGear = synth.gear
        }
        frame += n
        t += dt
    }
}

// WAV 16-bit PCM mono.
var peak: Float = 0
for s in samples { peak = max(peak, abs(s)) }
print(String(format: "szczyt %.3f, długość %.1f s", peak, total))
var data = Data()
func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
let bytes = samples.count * 2
data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVE".utf8))
data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
for s in samples { put(Int16(max(-32767, min(32767, s * 32767)))) }
try data.write(to: URL(fileURLWithPath: outPath))
print("zapisano \(outPath)")
