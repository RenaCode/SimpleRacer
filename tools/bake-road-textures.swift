// Wypieka tekstury jezdni do App/Ground: zużyta farba linii (road-paint), krawężnik (kerb + kerb-normal:
// farba, wytarcia, guma, kurz, spękania, zaokrąglona krawędź) i linia startu (start-line). Źródło: asfalt CC0.
// Użycie: swiftc -O tools/bake-road-textures.swift -o /tmp/bake && /tmp/bake App/Ground
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let dir = URL(fileURLWithPath: CommandLine.arguments[1])

// MARK: szum
func hash(_ x: Int, _ y: Int, _ seed: Int) -> Double {
    var h = UInt64(bitPattern: Int64(x &* 374761393 &+ y &* 668265263 &+ seed &* 2147483647))
    h = (h ^ (h >> 13)) &* 1274126177
    h ^= h >> 16
    return Double(h & 0xFFFFFF) / Double(0xFFFFFF)
}
/// Szum wartości kafelkujący się z okresem `period` komórek.
func vnoise(_ x: Double, _ y: Double, period: Int, seed: Int) -> Double {
    let xi = Int(floor(x)), yi = Int(floor(y))
    let fx = x - floor(x), fy = y - floor(y)
    let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
    func h(_ a: Int, _ b: Int) -> Double { hash(((a % period) + period) % period, ((b % period) + period) % period, seed) }
    let a = h(xi, yi), b = h(xi + 1, yi), c = h(xi, yi + 1), d = h(xi + 1, yi + 1)
    return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy
}
/// fbm w [0,1], kafelkujący się na obrazie (u, v w 0…1), `px`/`py` — liczba komórek najniższej oktawy.
func fbm(_ u: Double, _ v: Double, px: Int, py: Int, octaves: Int, seed: Int) -> Double {
    var sum = 0.0, amp = 0.5, norm = 0.0
    var fx = px, fy = py
    for o in 0..<octaves {
        // Szum anizotropowy: okres osobno w x i y — sklejamy przez skalowanie y.
        let n = vnoise2(u * Double(fx), v * Double(fy), periodX: fx, periodY: fy, seed: seed + o * 17)
        sum += n * amp; norm += amp
        amp *= 0.5; fx *= 2; fy *= 2
    }
    return sum / norm
}
func vnoise2(_ x: Double, _ y: Double, periodX: Int, periodY: Int, seed: Int) -> Double {
    let xi = Int(floor(x)), yi = Int(floor(y))
    let fx = x - floor(x), fy = y - floor(y)
    let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
    func h(_ a: Int, _ b: Int) -> Double { hash(((a % periodX) + periodX) % periodX, ((b % periodY) + periodY) % periodY, seed) }
    let a = h(xi, yi), b = h(xi + 1, yi), c = h(xi, yi + 1), d = h(xi + 1, yi + 1)
    return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy
}
func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
}
func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

// MARK: obrazy
struct Img {
    let w: Int, h: Int
    var px: [Double]  // RGB, wiersz 0 = góra obrazu
    init(w: Int, h: Int) { self.w = w; self.h = h; px = Array(repeating: 0, count: w * h * 3) }
    subscript(x: Int, y: Int) -> (Double, Double, Double) {
        get { let i = (y * w + x) * 3; return (px[i], px[i + 1], px[i + 2]) }
        set { let i = (y * w + x) * 3; px[i] = newValue.0; px[i + 1] = newValue.1; px[i + 2] = newValue.2 }
    }
    func save(_ name: String, quality: Double = 0.9) {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 { bytes[i * 4 + c] = UInt8(max(0, min(255, (px[i * 3 + c] * 255).rounded()))) }
        }
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = ctx.makeImage()!
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        print("zapisano \(name) \(w)×\(h)")
    }
}
func load(_ name: String, size: Int) -> Img {
    let src = CGImageSourceCreateWithURL(dir.appendingPathComponent(name) as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    let ctx = CGContext(data: &bytes, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    var out = Img(w: size, h: size)
    for i in 0..<(size * size) { for c in 0..<3 { out.px[i * 3 + c] = Double(bytes[i * 4 + c]) / 255 } }
    return out
}

let asphalt = load("road-asphalt.jpg", size: 1024)
// Progi wytarć dobrano do ciemnego asfaltu (średnia jasność 0,122); jaśniejszy asfalt ma te same wytarcia.
let lumScale: Double = {
    var s = 0.0
    for y in 0..<1024 { for x in 0..<1024 { let a = asphalt[x, y]; s += (a.0 + a.1 + a.2) / 3 } }
    return 0.122 / (s / 1024 / 1024)
}()

// MARK: 1. Farba linii: zdjęcie asfaltu przykryte białą farbą, wytartą plamami i na wierzchołkach kamyków.
// Kafel 4 m jak asfalt — UV linii są te same co jezdni, więc prześwity pokazują ten sam asfalt.
do {
    var img = Img(w: 1024, h: 1024)
    for y in 0..<1024 {
        for x in 0..<1024 {
            let u = Double(x) / 1024, v = Double(y) / 1024
            let a = asphalt[x, y]
            let lum = (a.0 + a.1 + a.2) / 3 * lumScale
            // Duże plamy wytarcia (koleiny) + drobne prześwity tam, gdzie kamyki asfaltu wystają (jasne).
            let big = fbm(u, v, px: 16, py: 16, octaves: 4, seed: 3)
            let fine = fbm(u, v, px: 64, py: 64, octaves: 2, seed: 9)
            var wear = smoothstep(0.66, 0.76, big) * 0.8 + smoothstep(0.66, 0.84, fine * 0.5 + lum * 0.8) * 0.75
            wear = min(1, wear)
            let paint = 1 - wear
            // Farba nie jest idealnie biała: lekko kremowa, przybrudzona nisko-częstotliwościowo,
            // z fakturą asfaltu prześwitującą przez cienką warstwę.
            let dirt = 0.86 + 0.12 * fbm(u, v, px: 3, py: 3, octaves: 3, seed: 21)
            let detail = 0.88 + 0.24 * (lum - 0.35)
            let pr = 0.93 * dirt * detail, pg = 0.92 * dirt * detail, pb = 0.88 * dirt * detail
            img[x, y] = (mix(a.0, pr, paint), mix(a.1, pg, paint), mix(a.2, pb, paint))
        }
    }
    img.save("road-paint.jpg")
}

// MARK: 2. Krawężnik: 1,2 m w poprzek (u, 0 = przy jezdni), 6 m wzdłuż (v): 3 m czerwieni, 3 m bieli.
do {
    let w = 256, h = 1024
    var img = Img(w: w, h: h)
    var height = Array(repeating: 0.0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            let u = (Double(x) + 0.5) / Double(w), v = 1 - (Double(y) + 0.5) / Double(h)
            let red = v < 0.5
            // Beton pod farbą.
            let conc = 0.5 + 0.12 * fbm(u, v, px: 8, py: 40, octaves: 5, seed: 5)
            let wearN = fbm(u, v, px: 10, py: 50, octaves: 4, seed: 7)
            let grit = fbm(u, v, px: 48, py: 240, octaves: 2, seed: 11)
            // Farba ściera się najbardziej przy jezdni (tam najeżdżają koła) i na krawędziach bloków.
            let joint = min(abs(v - 0.0), abs(v - 0.5), abs(v - 1.0)) * 6  // metry od spoiny
            let wear = min(1, smoothstep(0.76, 0.86, wearN + (1 - u) * 0.06 + grit * 0.1)
                + (joint < 0.02 ? 0.5 : 0))
            var c = red ? (0.70, 0.11, 0.09) : (0.90, 0.90, 0.87)
            let tone = 0.9 + 0.12 * fbm(u, v, px: 3, py: 12, octaves: 3, seed: 13)
            c = (c.0 * tone, c.1 * tone, c.2 * tone)
            var r = mix(c.0, conc * 0.98, wear), g = mix(c.1, conc * 0.96, wear), b = mix(c.2, conc * 0.92, wear)
            // Guma z opon: smugi wzdłuż jazdy w pasie przy jezdni.
            let rubber = smoothstep(0.55, 0.8, fbm(u, v, px: 12, py: 4, octaves: 4, seed: 17)) * (1 - smoothstep(0.15, 0.55, u))
            let k = 1 - 0.7 * rubber
            r *= k; g *= k; b *= k
            // Kurz i piasek naniesiony przy murze.
            let dust = smoothstep(0.7, 1.0, u) * (0.5 + 0.5 * fbm(u, v, px: 10, py: 50, octaves: 3, seed: 19))
            r = mix(r, 0.42, dust * 0.55); g = mix(g, 0.38, dust * 0.55); b = mix(b, 0.32, dust * 0.55)
            // Spękania betonu: cienkie, kręte rysy (izolinia szumu), ciemne i lekko wklęsłe.
            let field = fbm(u, v, px: 3, py: 12, octaves: 4, seed: 41)
            let crack = (1 - smoothstep(0.0, 0.006, abs(field - 0.5))) * smoothstep(0.55, 0.7, fbm(u, v, px: 2, py: 8, octaves: 2, seed: 43))
            r *= 1 - 0.6 * crack; g *= 1 - 0.6 * crack; b *= 1 - 0.6 * crack
            img[x, y] = (r, g, b)
            // Wysokość (m): zaokrąglona krawędź od strony jezdni, spoiny między blokami, chropowatość betonu.
            let bevel = -0.012 * (1 - smoothstep(0, 0.07, u))
            let jointH = joint < 0.012 ? -0.004 : 0
            height[y * w + x] = bevel + jointH + 0.0012 * grit + 0.0006 * wearN - wear * 0.0004 - crack * 0.0015
        }
    }
    img.save("kerb.jpg")
    // Normalne (OpenGL: zielony = +v) z różnic wysokości; piksel ma 1,2/256 m w poprzek i 6/1024 m wzdłuż.
    var nimg = Img(w: w, h: h)
    let dx = 1.2 / Double(w), dy = 6.0 / Double(h)
    for y in 0..<h {
        for x in 0..<w {
            let xl = max(0, x - 1), xr = min(w - 1, x + 1)
            let yu = (y - 1 + h) % h, yd = (y + 1) % h
            let gx = (height[y * w + xr] - height[y * w + xl]) / (Double(xr - xl) * dx)
            // Wiersz 0 to góra obrazu, czyli większe v.
            let gy = (height[yu * w + x] - height[yd * w + x]) / (2 * dy)
            var n = (-gx, -gy, 1.0)
            let l = (n.0 * n.0 + n.1 * n.1 + n.2 * n.2).squareRoot()
            n = (n.0 / l, n.1 / l, n.2 / l)
            nimg[x, y] = (n.0 * 0.5 + 0.5, n.1 * 0.5 + 0.5, n.2 * 0.5 + 0.5)
        }
    }
    nimg.save("kerb-normal.jpg", quality: 0.92)
}

// MARK: 3. Linia startu: szachownica 0,75 m w dwóch rzędach (6 m × 1,5 m na obraz), zużyta, ze śladami opon.
do {
    let w = 1024, h = 256
    var img = Img(w: w, h: h)
    for y in 0..<h {
        for x in 0..<w {
            let u = (Double(x) + 0.5) / Double(w), v = 1 - (Double(y) + 0.5) / Double(h)
            let col = Int(u * 8), row = Int(v * 2)
            let white = (col + row) % 2 == 0
            // Asfalt w tej samej skali co jezdnia (kafel 4 m = 1024 px; tu 6 m = 1024 px).
            let ax = Int(u * 6 / 4 * 1024) % 1024, ay = Int(v * 1.5 / 4 * 1024) % 1024
            let a = asphalt[ax, ay]
            let lum = (a.0 + a.1 + a.2) / 3 * lumScale
            let wear = min(1, smoothstep(0.68, 0.78, fbm(u, v, px: 16, py: 4, octaves: 4, seed: 23))
                + smoothstep(0.75, 0.92, fbm(u, v, px: 96, py: 24, octaves: 2, seed: 29) * 0.6 + lum * 0.7) * 0.6)
            let dirt = 0.85 + 0.15 * fbm(u, v, px: 4, py: 1, octaves: 3, seed: 31)
            let p = white ? 0.9 * dirt : 0.07
            var r = mix(a.0, p, 1 - wear), g = mix(a.1, p, 1 - wear), b = mix(a.2, p * 0.97, 1 - wear)
            // Ślady opon wzdłuż jazdy (oś v).
            let tyre = smoothstep(0.6, 0.85, fbm(u, v, px: 40, py: 1, octaves: 3, seed: 37))
            let k = 1 - 0.35 * tyre
            r *= k; g *= k; b *= k
            img[x, y] = (r, g, b)
        }
    }
    img.save("start-line.jpg")
}
