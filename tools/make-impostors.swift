// Renderuje „impostory” otoczenia: zdjęcia modelu z przodu i z boku z przezroczystym tłem.
// Gra składa z nich lekkie budynki (prostopadłościan obłożony zdjęciami) i drzewa (skrzyżowane płaszczyzny),
// zamiast rysować ciężkie modele 3D — tak jak gry mobilne robią dalszy i średni plan.
//
// Użycie: swift tools/make-impostors.swift LocalModels/Commercial
// Czyta scenery.json, zapisuje <folder>/impostors/*.png i <folder>/impostors.json.
import AppKit
import Foundation
import SceneKit

struct Entry: Decodable {
    let file: String
    let kind: String
    let regions: [String]
    let height: [Double]
    let split: String?
    let only: [String]?
    let max: Int?
    /// `false` — model nie nadaje się na impostor (np. brak tekstur w renderze).
    let impostor: Bool?
}

struct Impostor: Encodable {
    let name: String
    let kind: String
    let regions: [String]
    let height: [Double]
    let max: Int?
    /// Wymiary modelu w metrach przy jego oryginalnej skali (szerokość X, wysokość Y, głębokość Z).
    let size: [Double]
    let front: String
    let side: String
}

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "LocalModels/Commercial")
let outDir = folder.appendingPathComponent("impostors")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: folder.appendingPathComponent("scenery.json")))
let device = MTLCreateSystemDefaultDevice()!

/// Zdjęcie ortograficzne `node` wzdłuż osi `axis` (kamera patrzy na środek), `pixels` px w dłuższym boku.
func render(_ node: SCNNode, from axis: SIMD3<Float>, width: Float, height: Float, center: SCNVector3, pixels: Int) -> NSImage {
    let scene = SCNScene()
    scene.background.contents = NSColor.clear
    let holder = node.clone()
    scene.rootNode.addChildNode(holder)

    let cam = SCNCamera()
    cam.usesOrthographicProjection = true
    cam.orthographicScale = Double(height / 2) * 1.02
    cam.zNear = 0.01
    cam.zFar = 10_000
    let camNode = SCNNode()
    camNode.camera = cam
    let dist: Float = 1000
    camNode.position = SCNVector3(center.x + CGFloat(axis.x * dist), center.y + CGFloat(axis.y * dist), center.z + CGFloat(axis.z * dist))
    camNode.look(at: center)
    scene.rootNode.addChildNode(camNode)

    // Słońce z góry i z przodu + jasne otoczenie: równe, dzienne światło jak w panoramach.
    let sun = SCNNode()
    sun.light = SCNLight()
    sun.light!.type = .directional
    sun.light!.intensity = 900
    sun.eulerAngles = SCNVector3(-0.9, CGFloat(atan2(axis.x, axis.z)) + 0.5, 0)
    scene.rootNode.addChildNode(sun)
    let amb = SCNNode()
    amb.light = SCNLight()
    amb.light!.type = .ambient
    amb.light!.intensity = 550
    scene.rootNode.addChildNode(amb)

    let renderer = SCNRenderer(device: device, options: nil)
    renderer.scene = scene
    renderer.pointOfView = camNode
    let aspect = width / height
    let h = aspect > 1 ? Int(Float(pixels) / aspect) : pixels
    let w = aspect > 1 ? pixels : Int(Float(pixels) * aspect)
    return renderer.snapshot(atTime: 0, with: CGSize(width: max(8, w), height: max(8, h)), antialiasingMode: .multisampling4X)
}

func savePNG(_ image: NSImage, _ url: URL) {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

/// SceneKit nie zawsze podpina tekstury z USD (liście wychodzą białe albo niewidoczne). Jeśli obok modelu
/// jest katalog `textures/` (układ Poly Haven), składamy kolor `<materiał>_diff` z maską `<materiał>_alpha`.
func fixMaterials(_ root: SCNNode, textures: URL) {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: textures.path) else { return }
    func find(_ prefix: String, _ kind: String) -> URL? {
        names.first { $0.hasPrefix("\(prefix)_\(kind)_") && !$0.hasSuffix(".exr") }.map { textures.appendingPathComponent($0) }
    }
    var cache: [String: CGImage] = [:]
    root.enumerateHierarchy { n, _ in
        for m in n.geometry?.materials ?? [] {
            guard let name = m.name, let diffURL = find(name, "diff") else { continue }
            let alphaURL = find(name, "alpha")
            let key = name
            if cache[key] == nil, let rgba = compose(diffURL, alphaURL) { cache[key] = rgba }
            guard let img = cache[key] else { continue }
            m.diffuse.contents = img
            m.transparent.contents = nil
            m.transparency = 1
            m.transparencyMode = .aOne
            m.isDoubleSided = true
            m.blendMode = .alpha
        }
    }
}

func compose(_ diff: URL, _ alpha: URL?) -> CGImage? {
    guard let d = NSImage(contentsOf: diff)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let w = d.width, h = d.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let rect = CGRect(x: 0, y: 0, width: w, height: h)
    if let alpha, let a = NSImage(contentsOf: alpha)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
       let gray = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
        gray.draw(a, in: rect)
        // Obraz w odcieniach szarości jako maska przycięcia: białe (liść) widoczne, czarne przezroczyste.
        if let mask = gray.makeImage() {
            ctx.saveGState()
            ctx.clip(to: rect, mask: mask)
            ctx.draw(d, in: rect)
            ctx.restoreGState()
            return ctx.makeImage()
        }
    }
    ctx.draw(d, in: rect)
    return ctx.makeImage()
}

var out: [Impostor] = []
for e in entries where e.kind != "backdrop" && e.impostor != false {
    let url = folder.appendingPathComponent(e.file)
    guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false, .convertToYUp: true]) else {
        print("pomijam \(e.file): nie da się wczytać"); continue
    }
    fixMaterials(scene.rootNode, textures: url.deletingLastPathComponent().appendingPathComponent("textures"))
    var parts: [SCNNode]
    // Pliki Poly Haven trzymają kilka wariantów obok siebie (…_a_LOD0, …_b_LOD0) — każdy to osobny obiekt.
    var lods: [SCNNode] = []
    scene.rootNode.enumerateHierarchy { n, _ in if n.name?.hasSuffix("_LOD0") == true { lods.append(n) } }
    if e.split == nil && e.only == nil && !lods.isEmpty {
        parts = lods
    } else if let split = e.split, let n = scene.rootNode.childNode(withName: split, recursively: true) {
        parts = n.childNodes
    } else if let only = e.only {
        parts = only.compactMap { scene.rootNode.childNode(withName: $0, recursively: true) }
    } else {
        parts = [scene.rootNode]
    }
    let base = ((e.file as NSString).lastPathComponent as NSString).deletingPathExtension.replacingOccurrences(of: "_1k", with: "").replacingOccurrences(of: "_", with: "-")
    for (i, part) in parts.enumerated() {
        // Część w układzie świata pliku (z transformacjami rodziców).
        let holder = SCNNode()
        let copy = part.clone()
        if part !== scene.rootNode { copy.transform = part.worldTransform }
        holder.addChildNode(copy)
        let (lo, hi) = holder.boundingBox
        let sx = Float(hi.x - lo.x), sy = Float(hi.y - lo.y), sz = Float(hi.z - lo.z)
        guard sy > 0.001, sx > 0.001 else { continue }
        let c = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        let name = parts.count > 1 ? "\(base)-\(i)" : base
        let px = e.kind == "building" ? 1536 : 1024
        let front = render(holder, from: [0, 0, 1], width: sx, height: sy, center: c, pixels: px)
        let side = render(holder, from: [1, 0, 0], width: sz, height: sy, center: c, pixels: px)
        savePNG(front, outDir.appendingPathComponent("\(name)-front.png"))
        savePNG(side, outDir.appendingPathComponent("\(name)-side.png"))
        out.append(Impostor(name: name, kind: e.kind, regions: e.regions, height: e.height, max: e.max,
                            size: [Double(sx), Double(sy), Double(sz)],
                            front: "impostors/\(name)-front.png", side: "impostors/\(name)-side.png"))
        print("\(name): \(String(format: "%.1f × %.1f × %.1f", sx, sy, sz))")
    }
}
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try enc.encode(out).write(to: folder.appendingPathComponent("impostors.json"))
print("zapisano \(out.count) impostorów")
