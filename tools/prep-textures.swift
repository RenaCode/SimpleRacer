// Przygotowanie tekstur otoczenia do App/Ground (CoreGraphics, bez zależności).
//   swiftc -O tools/prep-textures.swift -o /tmp/prep
//   /tmp/prep ao <color.jpg> <ao.jpg> <out.jpg> [size]   — kolor × okluzja (spoiny ciemniejsze bez mapy AO w grze)
//   /tmp/prep gain <in.jpg> <out.jpg> <mean> [size] [desat] — jasność w przestrzeni liniowej tak, by średnia sRGB = mean;
//                                                          desat 0…1 przybliża kolor do szarości (kamień asfaltu jest szary)
//   /tmp/prep copy <in.jpg> <out.jpg> [size]             — samo skalowanie (np. mapa normalnych)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
func load(_ p: String, _ size: Int) -> [UInt8] {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    var px = [UInt8](repeating: 0, count: size * size * 4)
    let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    return px
}
func save(_ px: [UInt8], _ size: Int, _ p: String) {
    var px = px
    let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: p) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
    CGImageDestinationFinalize(dst)
}
func lin(_ v: UInt8) -> Double { let c = Double(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
func srgb(_ l: Double) -> UInt8 {
    let c = l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055
    return UInt8(max(0, min(255, (c * 255).rounded())))
}
switch a[1] {
case "ao":
    let size = a.count > 5 ? Int(a[5])! : 1024
    let c = load(a[2], size), o = load(a[3], size)
    var out = c
    for i in stride(from: 0, to: c.count, by: 4) {
        let ao = Double(o[i]) / 255
        for k in 0..<3 { out[i + k] = srgb(lin(c[i + k]) * ao) }
    }
    save(out, size, a[4])
case "gain":
    let size = a.count > 5 ? Int(a[5])! : 1024
    var c = load(a[2], size)
    let target = Double(a[4])!, desat = a.count > 6 ? Double(a[6])! : 0
    if desat > 0 {
        for i in stride(from: 0, to: c.count, by: 4) {
            let l = (0..<3).map { lin(c[i + $0]) }, y = 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
            for k in 0..<3 { c[i + k] = srgb(l[k] + (y - l[k]) * desat) }
        }
    }
    // Szukamy mnożnika w liniowym (bisekcja), bo obcinanie jasnych pikseli zmienia średnią nieliniowo.
    func mean(_ k: Double) -> Double {
        var s = 0.0
        for i in stride(from: 0, to: c.count, by: 4) { for j in 0..<3 { s += Double(srgb(lin(c[i + j]) * k)) } }
        return s / Double(c.count / 4 * 3)
    }
    var lo = 0.05, hi = 40.0
    for _ in 0..<30 { let m = (lo + hi) / 2; if mean(m) < target { lo = m } else { hi = m } }
    var out = c
    for i in stride(from: 0, to: c.count, by: 4) { for j in 0..<3 { out[i + j] = srgb(lin(c[i + j]) * lo) } }
    save(out, size, a[3])
    print(String(format: "mnożnik liniowy %.2f, średnia %.1f", lo, mean(lo)))
case "copy":
    let size = a.count > 4 ? Int(a[4])! : 1024
    save(load(a[2], size), size, a[3])
default:
    print("ao | gain | copy")
}
