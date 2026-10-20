// Panorama HDR (Poly Haven, .hdr/.exr) → App/Sky/sky-<kraina>-ibl.exr: źródło oświetlenia i odbić (IBL).
// Tarcza słońca w HDR ma dziesiątki tysięcy jednostek — w połówkowej precyzji to nieskończoność, a w odbiciach
// migoczące piksele. Ograniczamy jasność do `max` z zachowaniem barwy: energię słońca i tak daje światło
// kierunkowe sceny, a w lakierze zostaje ostry, przepalony odblask.
// Z `tło.jpg` (panorama tła, App/Sky/sky-<kraina>.jpg) ekspozycja HDR jest dopasowana do zdjęcia tła — odbicia
// mają jasność tego, co widać za autem — a narzędzie sprawdza, czy obie panoramy nie są względem siebie obrócone.
// Użycie: swiftc -O tools/make-ibl.swift -o /tmp/make-ibl && /tmp/make-ibl wejście.hdr App/Sky/sky-city-ibl.exr [max=64] [tło.jpg]
import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count >= 3 else { print("użycie: make-ibl <wejście.hdr> <wyjście.exr> [max]"); exit(1) }
var maxValue = args.count > 3 ? Float(args[3]) ?? 64 : 64
let reference = args.count > 4 ? args[4] : nil

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary)
else { print("nie da się wczytać \(args[1])"); exit(1) }

let w = image.width, h = image.height
let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
    | CGBitmapInfo.byteOrder32Little.rawValue
var px = [Float](repeating: 0, count: w * h * 4)
guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                          space: space, bitmapInfo: info) else { exit(1) }
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

/// Zdjęcie tła w liniowym RGB w rozmiarze HDR.
func linearPixels(_ path: String) -> [Float]? {
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return nil }
    var out = [Float](repeating: 0, count: w * h * 4)
    guard let c = CGContext(data: &out, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                            space: space, bitmapInfo: info) else { return nil }
    c.interpolationQuality = .high
    c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return out
}

if let reference, let ref = linearPixels(reference) {
    func luma(_ a: [Float], _ i: Int) -> Float { 0.2126 * a[i * 4] + 0.7152 * a[i * 4 + 1] + 0.0722 * a[i * 4 + 2] }
    // Obrót: przesunięcie w poziomie o najmniejszej różnicy logarytmów jasności (co 1/64 obwodu).
    var best = (shift: 0, err: Float.infinity)
    for k in 0..<64 {
        let dx = k * w / 64
        var err: Float = 0
        for y in stride(from: h / 8, to: h * 7 / 8, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                let a = luma(px, y * w + (x + dx) % w), b = luma(ref, y * w + x)
                guard a.isFinite, a > 0.001, b > 0.001 else { continue }
                err += abs(log(a) - log(b))
            }
        }
        if err < best.err { best = (dx, err) }
    }
    // Ekspozycja: mediana stosunku jasności zdjęcia do HDR w miejscach, których zdjęcie nie przepaliło.
    var ratios = [Float]()
    for i in stride(from: 0, to: w * h, by: 3) {
        let a = luma(px, i), b = luma(ref, i)
        if a.isFinite, a > 0.005, b > 0.02, b < 0.8 { ratios.append(b / a) }
    }
    ratios.sort()
    let gain = ratios.isEmpty ? 1 : ratios[ratios.count / 2]
    print(String(format: "tło: przesunięcie %d px z %d (%.1f°), ekspozycja ×%.2f", best.shift, w,
                 Float(best.shift) / Float(w) * 360, gain))
    if best.shift != 0 && best.shift != w { print("UWAGA: panoramy są obrócone względem siebie") }
    for i in 0..<(w * h * 4) where i % 4 != 3 { px[i] *= gain }
    // Łączna energia nie więcej niż 10% ponad zdjęcie: na tej samej sile IBL (`intensityExponent`) scena
    // nie jaśnieje. Najpierw niżej przycinamy najjaśniejsze źródła (lampy hali), w ostateczności skalujemy całość.
    func mean(_ a: [Float], clamp: Float) -> Float {
        var sum: Float = 0
        for i in 0..<(w * h) {
            var l = luma(a, i)
            if !l.isFinite { l = clamp }
            sum += min(l, clamp)
        }
        return sum / Float(w * h)
    }
    let target = mean(ref, clamp: 1) * 1.1
    while maxValue > 8, mean(px, clamp: maxValue) > target { maxValue /= 1.25 }
    let m = mean(px, clamp: maxValue)
    if m > target {
        for i in 0..<(w * h * 4) where i % 4 != 3 { px[i] *= target / m }
    }
    print(String(format: "energia: %.3f (zdjęcie %.3f), próg %.0f%@", min(m, target), target / 1.1, maxValue,
                 m > target ? String(format: ", skala ×%.2f", target / m) : ""))
}

var clipped = 0, peak: Float = 0
for i in 0..<(w * h) {
    var c = SIMD3(px[i * 4], px[i * 4 + 1], px[i * 4 + 2])
    // Nieskończoność (przepełnienie half przy dekodowaniu) = najjaśniejszy możliwy piksel.
    c = SIMD3(c.x.isFinite ? c.x : maxValue, c.y.isFinite ? c.y : maxValue, c.z.isFinite ? c.z : maxValue)
    c = pointwiseMax(c, .zero)
    let m = max(c.x, max(c.y, c.z))
    peak = max(peak, m)
    if m > maxValue { c *= maxValue / m; clipped += 1 }
    px[i * 4] = c.x; px[i * 4 + 1] = c.y; px[i * 4 + 2] = c.z; px[i * 4 + 3] = 1
}

guard let out = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                 "com.ilm.openexr-image" as CFString, 1, nil)
else { print("nie da się zapisać EXR"); exit(1) }
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else { print("zapis EXR nieudany"); exit(1) }
print(String(format: "%@: %dx%d, szczyt %.0f, przycięte %d px do %.0f", args[2], w, h, peak, clipped, maxValue))
