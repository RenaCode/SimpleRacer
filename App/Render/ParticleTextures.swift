import RealityKit
import UIKit

/// Tekstury cząsteczek. Emiter bez obrazka rysuje każdą cząsteczkę jako jednolity kwadrat, więc dym
/// składał się z widocznych prostokątów. Kłąb dymu to miękka, nieregularna plama (szum na gradiencie
/// promienistym, zero na brzegach); iskry i płomienie — rozmyta kropka.
@MainActor
enum ParticleTextures {
    static let smoke: TextureResource? = make(size: 128) { x, y in
        let r = (x * x + y * y).squareRoot()
        let falloff = max(0, 1 - r)
        // Nieregularny brzeg: kilka oktaw gładkiego szumu modulujących promień.
        let a = atan2(y, x)
        let wobble = 0.12 * sin(a * 3 + 1.3) + 0.07 * sin(a * 7 + 0.4) + 0.04 * sin(a * 13 + 2.2)
        let edge = max(0, min(1, (1 - r / (0.82 + wobble)) * 2.2))
        let body = pow(falloff, 1.6) * edge
        // Wewnętrzna faktura (kłębienie), słaba — dym przy ruchu i tak się rozmywa.
        let swirl = 0.85 + 0.15 * sin(x * 9.1 + y * 4.3) * sin(y * 7.7 - x * 3.1)
        return body * swirl
    }

    static let dot: TextureResource? = make(size: 64) { x, y in
        let r = (x * x + y * y).squareRoot()
        let v = max(0, 1 - r)
        return v * v
    }

    /// Obraz w odcieniach szarości (biały = widoczny), `f` dostaje współrzędne −1…1.
    private static func make(size n: Int, _ f: (Double, Double) -> Double) -> TextureResource? {
        var rgba = [UInt8](repeating: 0, count: n * n * 4)
        for j in 0..<n {
            for i in 0..<n {
                let x = (Double(i) + 0.5) / Double(n) * 2 - 1, y = (Double(j) + 0.5) / Double(n) * 2 - 1
                let v = UInt8(max(0, min(1, f(x, y))) * 255)
                let k = (j * n + i) * 4
                // Biel z alfą (premultiplied): kolor cząsteczki nadaje emiter.
                rgba[k] = v; rgba[k + 1] = v; rgba[k + 2] = v; rgba[k + 3] = v
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return try? TextureResource(image: image, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
    }
}
