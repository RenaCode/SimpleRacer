import Foundation
import RealityKit

/// Krzywa tonów i poświata liczone przez RealityKit jeszcze w HDR (iOS 27+). Własna obróbka obrazu
/// (`RacePostEffect`) dostaje już obraz 8-bitowy sRGB po tonemappingu silnika — nie odróżni słońca
/// w lakierze od białej chmury. Tu progi i krzywa działają na prawdziwej jasności.
@MainActor
enum CinematicLook {
    struct Params {
        /// ToneMappingComponent: ekspozycja (EV), palce (cienie) i ramię (światła) krzywej. Względem krzywej
        /// silnika (0; 0,25; 0,37; 1; 0,7; 1): mocniejsze i dłuższe palce — głębszy kontrast i nasycenie
        /// lakieru — łagodniejsze ramię (jasne miejsca dochodzą do bieli wolniej), +0,25 EV na pociemnienie
        /// od palców. Wybrane z czterech wariantów na zrzutach garażu, miasta i śniegu.
        var exposure: Float = 0.25, toeStrength: Float = 0.6, toeLength: Float = 0.5
        var shoulderStrength: Float = 0.85, shoulderLength: Float = 0.8, shoulderAngle: Float = 1
        /// BloomOptionsComponent; `bloomStrength` 0 — bez poświaty silnika. Na symulatorze (iOS 27.0) się nie
        /// składa (`ecs.BloomComponent <compose failure>`, brak efektu nawet przy sile 8), więc domyślnie
        /// wyłączona — do sprawdzenia na iPadzie: `-bloomHDR 1,1.2,1`.
        var bloomStrength: Float = 0, bloomThreshold: Float = 1, bloomRadius: Float = 1
        /// Encja z komponentami: 0 — kamera, 1 — korzeń sceny, -1 — bez komponentów (krzywa silnika).
        var holder = 0
    }

    static let params: Params = {
        var p = Params()
        #if DEBUG || FAMILY
        // Strojenie bez przebudowy: `-tm ekspozycja,palceSiła,palceDł,ramięSiła,ramięDł,ramięKąt`,
        // `-bloomHDR siła,próg,promień`, `-holder 0|1|-1`.
        let args = ProcessInfo.processInfo.arguments
        func values(_ name: String) -> [Float]? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1].split(separator: ",").compactMap { Float($0) }
        }
        if let v = values("-tm"), v.count == 6 {
            (p.exposure, p.toeStrength, p.toeLength) = (v[0], v[1], v[2])
            (p.shoulderStrength, p.shoulderLength, p.shoulderAngle) = (v[3], v[4], v[5])
        }
        if let v = values("-bloomHDR"), v.count == 3 { (p.bloomStrength, p.bloomThreshold, p.bloomRadius) = (v[0], v[1], v[2]) }
        if let v = values("-holder"), let h = v.first { p.holder = Int(h) }
        #endif
        return p
    }()

    /// Czy silnik sam liczy poświatę — wtedy własna (z obrazu 8-bitowego) jest zbędna.
    static var nativeBloom: Bool {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { return params.bloomStrength > 0 }
        #endif
        return false
    }

    /// Komponenty z SDK iOS 27 (Xcode 27, Swift 6.4) — starszy Xcode (np. 26.3 w CI) ich nie zna,
    /// więc kod jest kompilowany warunkowo; aplikacja z takiego buildu ma krzywą silnika.
    static func apply(root: Entity, camera: Entity) {
        #if compiler(>=6.4)
        guard #available(iOS 27.0, *) else { return }
        let p = params
        guard p.holder >= 0 else { return }
        let holder = p.holder == 1 ? root : camera
        holder.components.set(ToneMappingComponent(exposure: p.exposure, toeStrength: p.toeStrength, toeLength: p.toeLength,
                                                   shoulderStrength: p.shoulderStrength, shoulderLength: p.shoulderLength,
                                                   shoulderAngle: p.shoulderAngle))
        if p.bloomStrength > 0 {
            var options = BloomOptionsComponent()
            options.strength = p.bloomStrength
            options.threshold = p.bloomThreshold
            options.blurRadius = p.bloomRadius
            holder.components.set(options)
            root.components.set(BloomComponent(scope: .unbounded))
        }
        #endif
    }
}
