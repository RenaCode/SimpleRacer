// Generuje ikonę aplikacji (1024×1024 PNG): `swift tools/make-icon.swift <wyjście.png>`.
import AppKit
import CoreGraphics

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!  // ikona iOS nie może mieć kanału alfa
let S = CGFloat(size)
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }

// Tło: ukośny gradient granat → fiolet.
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0.06, 0.07, 0.16), rgb(0.16, 0.08, 0.38)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

// Szachownica: ukośny pas w dolnej części.
ctx.saveGState()
ctx.translateBy(x: S / 2, y: S * 0.2)
ctx.rotate(by: .pi / 14)
let cell: CGFloat = 64
for row in 0..<2 {
    for col in -12..<12 {
        ctx.setFillColor((row + col) % 2 == 0 ? rgb(0.95, 0.95, 0.97) : rgb(0.08, 0.08, 0.1))
        ctx.fill(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
    }
}
ctx.restoreGState()

// Smugi prędkości za literami.
for (i, y) in [0.70, 0.60, 0.50].enumerated() {
    ctx.setFillColor(rgb(1, 0.84, 0.04, 0.85 - CGFloat(i) * 0.2))
    let h: CGFloat = 26 - CGFloat(i) * 6
    let path = CGPath(roundedRect: CGRect(x: S * 0.06, y: S * y, width: S * (0.42 - CGFloat(i) * 0.08), height: h),
                      cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
    ctx.addPath(path)
    ctx.fillPath()
}

// Monogram „SR”: pochylony, ciężki krój, żółty z ciemnym cieniem.
let font = NSFont.systemFont(ofSize: 470, weight: .black)
let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
let para = NSMutableParagraphStyle()
para.alignment = .center
func draw(_ text: String, color: NSColor, dx: CGFloat, dy: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: italic, .foregroundColor: color, .paragraphStyle: para, .kern: -18]
    let str = NSAttributedString(string: text, attributes: attrs)
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    // Pochylenie (skos) dodatkowo, żeby litery „jechały”.
    var t = CGAffineTransform(a: 1, b: 0, c: 0.18, d: 1, tx: -S * 0.08 + dx, ty: dy)
    ctx.concatenate(t)
    str.draw(in: CGRect(x: S * 0.06, y: S * 0.3, width: S, height: 560))
    t = t.inverted()
    ctx.concatenate(t)
    NSGraphicsContext.restoreGraphicsState()
}
draw("SR", color: NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 0.45), dx: 14, dy: -16)
draw("SR", color: NSColor(calibratedRed: 1, green: 0.84, blue: 0.04, alpha: 1), dx: 0, dy: 0)

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("zapisano", out)
