import Foundation

/// Klasa urządzenia: iPady z chipem A (do 6 GB RAM, np. iPad A16 dzieci) mają wyraźnie mniej zapasu GPU niż iPady
/// z chipem M (8 GB i więcej). Na iPadzie A16 wyścig jechał w większości ~20 kl./s; cienie od słońca rysują scenę
/// drugi raz, więc tam ich zasięg jest krótszy (cień zostaje pod autem gracza i rywalami w pobliżu).
enum DeviceTier {
    static let isLowGPU: Bool = {
        #if DEBUG || FAMILY
        // `-lowTier` / `-highTier`: wymuszenie klasy (symulator ma pamięć Maca, więc sam z siebie jest „wysoki”).
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-lowTier") { return true }
        if args.contains("-highTier") { return false }
        #endif
        return ProcessInfo.processInfo.physicalMemory < 7_500_000_000
    }()

    /// Zasięg mapy cieni słońca (m).
    static let shadowDistance: Float = {
        #if DEBUG || FAMILY
        // `-shadowDistance 50`: pomiar A/B na urządzeniu.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-shadowDistance"), i + 1 < args.count, let d = Float(args[i + 1]) { return d }
        #endif
        return isLowGPU ? 35 : 80
    }()

    /// `-noShadow`: wyścig bez cieni słońca (tylko pomiar; w grze cienie zostają).
    static let shadowsOn: Bool = {
        #if DEBUG || FAMILY
        return !ProcessInfo.processInfo.arguments.contains("-noShadow")
        #else
        return true
        #endif
    }()
}
