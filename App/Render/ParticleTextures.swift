import RealityKit
import UIKit

/// Tekstury cząsteczek. Emiter bez obrazka rysuje każdą cząsteczkę jako jednolity kwadrat. Iskry to
/// rozmyta kropka; jasność w kolorze (bez kanału alfa), bo emiter rysuje je addytywnie — przy mieszaniu
/// przez alfę RealityKit ucinał przezroczystość progiem i miały ostre brzegi krążków. Kłąb dymu to miękka
/// plama (gęstość opada jak krzywa Gaussa) w pasku wygasania dla `DriftSmoke` (maska przezroczystości).
@MainActor
enum ParticleTextures {
    /// Kłąb dymu, `x`, `y` w −1…1.
    private static func puff(_ x: Double, _ y: Double) -> Double {
        // Gęstość opada łagodnie (krzywa Gaussa) do zera na brzegu — bez konturu, który przy wielu
        // nałożonych cząsteczkach dawał „komiksowe” chmurki.
        let r2 = x * x + y * y
        let density = exp(-r2 * 3.2) * max(0, 1 - r2)
        // Nierównomierność wewnątrz kłębu (kilka łagodnych fal), żeby dym nie był jednolitą mgłą.
        let swirl = 0.7 + 0.3 * (0.5 + 0.5 * sin(x * 5.3 + y * 2.9 + 0.7) * sin(y * 4.1 - x * 2.2 + 1.9))
        return density * swirl
    }

    /// Pasek `steps` kłębów o gęstości malejącej od pełnej do zera — przezroczystość dymu w `DriftSmoke`
    /// (maska w kanale R, liniowo). Brzegi kłębu mają gęstość 0, więc mipmapy nie przeciekają między kopiami.
    static func smokeFadeStrip(steps: Int, cell n: Int = 64) -> TextureResource? {
        var gray = [UInt8](repeating: 0, count: n * steps * n)
        for j in 0..<n {
            for i in 0..<(n * steps) {
                let level = 1 - (Double(i / n) + 0.5) / Double(steps)
                let x = (Double(i % n) + 0.5) / Double(n) * 2 - 1, y = (Double(j) + 0.5) / Double(n) * 2 - 1
                gray[j * n * steps + i] = UInt8(max(0, min(1, puff(x, y) * level)) * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let image = CGImage(width: n * steps, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n * steps,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return try? TextureResource(image: image, options: .init(semantic: .raw, mipmapsMode: .allocateAndGenerateAll))
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
                // Jasność = gęstość; kolor cząsteczki nadaje emiter.
                rgba[k] = v; rgba[k + 1] = v; rgba[k + 2] = v; rgba[k + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return try? TextureResource(image: image, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
    }
}
