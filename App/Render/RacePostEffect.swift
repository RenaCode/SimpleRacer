import Metal
import MetalPerformanceShaders
import RealityKit
import simd
import UIKit

/// Ustawienia obróbki obrazu wyścigu — kolor mgły zależy od krainy (kolor horyzontu panoramy).
struct PostFXSettings: Sendable {
    var fogColor: SIMD3<Float> = [0.72, 0.78, 0.86]
    var fogDensity: Float = 0.35
    var fogScale: Float = 650
    var fogEnd: Float = 1800
    var bloom: Float = 0.45
    var bloomThreshold: Float = 0.78
    var vignette: Float = 0.14
    var saturation: Float = 1.08
    var contrast: Float = 0.06
}

/// Obróbka obrazu jak w grach wyścigowych (iOS 26+): poświata jasnych miejsc (odblaski na lakierze,
/// słońce w szybach), mgła powietrzna z bufora głębi (dal „odpływa” w kolor horyzontu, budynki i drzewa
/// mają głębię zamiast płaskich wycinanek), łagodna krzywa tonów, nasycenie i winieta.
/// Koszt: jeden przebieg pełnoekranowy + jasne miejsca i rozmycie w ćwiartce rozdzielczości.
@available(iOS 26.0, *)
struct RacePostEffect: PostProcessEffect {
    private let state: State

    init(settings: PostFXSettings) {
        var s = settings
        #if DEBUG || FAMILY
        // `-postFXTest`: przesadzona winieta — widać na zrzucie, że obróbka działa.
        if ProcessInfo.processInfo.arguments.contains("-postFXTest") { s.vignette = 0.95 }
        #endif
        state = State(settings: s)
    }

    mutating func prepare(for device: any MTLDevice) {
        debugLog("obróbka obrazu: prepare")
        state.prepare(device)
    }

    mutating func postProcess(context: borrowing PostProcessEffectContext<any MTLCommandBuffer>) {
        state.encode(commandBuffer: context.commandBuffer, source: context.sourceColorTexture,
                     depth: context.sourceDepthTexture, target: context.targetColorTexture,
                     projection: context.projection)
    }

    /// Tekstury pośrednie — tworzone raz na rozmiar ekranu, używane tylko z wątku renderowania.
    private final class State: @unchecked Sendable {
        let settings: PostFXSettings
        private var device: (any MTLDevice)?
        private var pipelines: PostFXPipelines?
        private var glowA: (any MTLTexture)?
        private var glowB: (any MTLTexture)?
        private var loggedFormat = false

        init(settings: PostFXSettings) { self.settings = settings }

        func prepare(_ device: any MTLDevice) {
            guard self.device == nil else { return }
            self.device = device
            pipelines = PostFXPipelines.shared(for: device)
        }

        private func glowTextures(for source: any MTLTexture) -> (any MTLTexture, any MTLTexture)? {
            let w = max(1, source.width / 4), h = max(1, source.height / 4)
            if let a = glowA, let b = glowB, a.width == w, a.height == h { return (a, b) }
            guard let device else { return nil }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            glowA = device.makeTexture(descriptor: d)
            glowB = device.makeTexture(descriptor: d)
            guard let a = glowA, let b = glowB else { return nil }
            return (a, b)
        }

        func encode(commandBuffer: any MTLCommandBuffer, source: any MTLTexture, depth: any MTLTexture,
                    target: any MTLTexture, projection: simd_float4x4) {
            if device == nil { prepare(commandBuffer.device) }
            #if DEBUG || FAMILY
            if !loggedFormat {
                loggedFormat = true
                debugLog("obróbka obrazu: źródło \(source.pixelFormat.rawValue) typ \(source.textureType.rawValue) próbki \(source.sampleCount), cel \(target.pixelFormat.rawValue) typ \(target.textureType.rawValue), głębia \(depth.pixelFormat.rawValue) typ \(depth.textureType.rawValue) próbki \(depth.sampleCount), \(source.width)×\(source.height) / głębia \(depth.width)×\(depth.height)")
            }
            #endif
            guard let pipelines, let bright = pipelines.bright, let blur = pipelines.blur,
                  let pipeline = pipelines.composite(target.pixelFormat),
                  let (glowA, glowB) = glowTextures(for: source) else {
                copy(commandBuffer, source, target)
                return
            }
            // 1. Jasne miejsca w ćwiartce rozdzielczości.
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.setComputePipelineState(bright)
                enc.setTexture(source, index: 0)
                enc.setTexture(glowA, index: 1)
                var threshold = settings.bloomThreshold
                enc.setBytes(&threshold, length: MemoryLayout<Float>.size, index: 0)
                let tg = MTLSize(width: 8, height: 8, depth: 1)
                enc.dispatchThreadgroups(MTLSize(width: (glowA.width + 7) / 8, height: (glowA.height + 7) / 8, depth: 1),
                                         threadsPerThreadgroup: tg)
                enc.endEncoding()
            }
            // 2. Rozmycie (MPS).
            blur.encode(commandBuffer: commandBuffer, sourceTexture: glowA, destinationTexture: glowB)
            // 3. Złożenie: mgła, poświata, tony → obraz docelowy.
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            let s = settings
            let isLinear = Self.isLinear(source.pixelFormat)
            let fog = isLinear ? SIMD3(powf(s.fogColor.x, 2.2), powf(s.fogColor.y, 2.2), powf(s.fogColor.z, 2.2)) : s.fogColor
            var u = Uniforms(fog: SIMD4(fog, s.fogDensity),
                             depth: SIMD2(projection.columns.2.z, projection.columns.3.z),
                             fogScale: s.fogScale, fogEnd: s.fogEnd, bloom: s.bloom, vignette: s.vignette,
                             saturation: s.saturation, contrast: s.contrast, linear: isLinear ? 1 : 0)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(source, index: 0)
            enc.setFragmentTexture(glowB, index: 1)
            enc.setFragmentTexture(depth, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        /// Zapas: bez potoków obraz przechodzi bez zmian.
        private func copy(_ cb: any MTLCommandBuffer, _ source: any MTLTexture, _ target: any MTLTexture) {
            guard let blit = cb.makeBlitCommandEncoder() else { return }
            blit.copy(from: source, to: target)
            blit.endEncoding()
        }

        private static func isLinear(_ f: MTLPixelFormat) -> Bool {
            switch f {
            case .bgra8Unorm_srgb, .rgba8Unorm_srgb, .rgba16Float, .rg11b10Float, .rgb9e5Float, .rgba32Float,
                 .bgr10_xr_srgb, .bgra10_xr_srgb:
                return true
            default:
                return false
            }
        }

        /// Układ zgodny z `PostUniforms` w PostFX.metal.
        struct Uniforms {
            var fog: SIMD4<Float>
            var depth: SIMD2<Float>
            var fogScale: Float
            var fogEnd: Float
            var bloom: Float
            var vignette: Float
            var saturation: Float
            var contrast: Float
            var linear: Float
        }
    }
}

/// Skompilowane potoki obróbki obrazu, wspólne dla wszystkich wyścigów. Kompilacja shaderów trwa
/// na symulatorze ok. 2 s — `warmUp()` robi ją w tle przy starcie aplikacji, żeby pierwszy wyścig
/// nie czekał na nią w pierwszej klatce.
final class PostFXPipelines: @unchecked Sendable {
    let device: any MTLDevice
    let bright: (any MTLComputePipelineState)?
    let blur: MPSImageGaussianBlur?
    private let library: (any MTLLibrary)?
    private let lock = NSLock()
    private var composites: [MTLPixelFormat: any MTLRenderPipelineState] = [:]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: PostFXPipelines?

    /// Formaty, w jakich RealityKit podaje obraz (sRGB 8 bit albo HDR 16 bit) — kompilowane z góry.
    private static let likelyFormats: [MTLPixelFormat] = [.bgra8Unorm_srgb, .rgba16Float, .bgra8Unorm, .rgba8Unorm_srgb]

    private init(device: any MTLDevice) {
        self.device = device
        library = try? device.makeDefaultLibrary(bundle: .main)
        bright = library?.makeFunction(name: "postBright").flatMap { try? device.makeComputePipelineState(function: $0) }
        let b = MPSImageGaussianBlur(device: device, sigma: 6)
        b.edgeMode = .clamp
        blur = b
    }

    static func shared(for device: any MTLDevice) -> PostFXPipelines {
        lock.lock(); defer { lock.unlock() }
        if let c = cache, c.device.registryID == device.registryID { return c }
        let c = PostFXPipelines(device: device)
        cache = c
        return c
    }

    /// Kompilacja w tle przy starcie aplikacji.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            guard let device = MTLCreateSystemDefaultDevice() else { return }
            let start = ProcessInfo.processInfo.systemUptime
            let p = shared(for: device)
            for f in likelyFormats { _ = p.composite(f) }
            debugLog(String(format: "obróbka obrazu: shadery gotowe w %.2f s", ProcessInfo.processInfo.systemUptime - start))
        }
    }

    func composite(_ format: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
        lock.lock(); defer { lock.unlock() }
        if let p = composites[format] { return p }
        guard let library, let v = library.makeFunction(name: "postVertex"),
              let f = library.makeFunction(name: "postComposite") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v
        d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = format
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        composites[format] = p
        return p
    }
}

extension PostFXSettings {
    /// Kolor mgły z panoramy krainy: średnia z pasa tuż nad horyzontem małego zdjęcia nieba.
    static func forRegion(_ key: String) -> PostFXSettings {
        var s = PostFXSettings()
        guard let url = Bundle.main.url(forResource: "sky-\(key)", withExtension: "jpg"),
              let image = UIImage(contentsOfFile: url.path)?.cgImage else { return s }
        let w = 64, h = 32
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return s }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return s }
        // Panorama równoprostokątna: horyzont w połowie wysokości; bierzemy 44–49% od góry (tuż nad nim).
        // W pamięci kontekstu wiersze idą od góry obrazu.
        var sum = SIMD3<Float>(repeating: 0), n: Float = 0
        for row in Int(Float(h) * 0.44)...Int(Float(h) * 0.49) {
            for x in 0..<w {
                let p = data + (row * w + x) * 4
                sum += SIMD3(Float(p[0]), Float(p[1]), Float(p[2])) / 255
                n += 1
            }
        }
        if n > 0 {
            // Mgła jaśniejsza i chłodniejsza niż średnia (rozpraszanie w powietrzu), nie ciemny pas budynków.
            let avg = sum / n
            s.fogColor = simd_mix(avg, SIMD3<Float>(0.78, 0.84, 0.92), SIMD3(repeating: 0.45))
        }
        return s
    }
}

/// Kierunek i barwa słońca odczytane z panoramy krainy (zdjęcie równoprostokątne, jak kopuła nieba).
struct SunEstimate {
    var direction: SIMD3<Float>
    var color: UIColor
    var fromPhoto: Bool

    static let fallback = SunEstimate(direction: simd_normalize(SIMD3<Float>(80, 140, 40)), color: .white, fromPhoto: false)

    static func from(region key: String) -> SunEstimate {
        guard let url = Bundle.main.url(forResource: "sky-\(key)", withExtension: "jpg"),
              let image = UIImage(contentsOfFile: url.path)?.cgImage else { return fallback }
        let w = 256, h = 128
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return fallback }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return fallback }
        func luma(_ x: Int, _ y: Int) -> Float {
            let p = data + (y * w + x) * 4
            return 0.2126 * Float(p[0]) + 0.7152 * Float(p[1]) + 0.0722 * Float(p[2])
        }
        // Najjaśniejsze miejsce nieba (górna połowa, bez samego zenitu) i średnia jasność nieba.
        var best = (x: 0, y: 0, l: Float(0)), sum: Float = 0, n: Float = 0
        for y in Int(Float(h) * 0.05)..<Int(Float(h) * 0.47) {
            for x in 0..<w {
                let l = luma(x, y)
                sum += l; n += 1
                if l > best.l { best = (x, y, l) }
            }
        }
        // Słońce musi wyraźnie odstawać od nieba — przy zachmurzeniu zostaje kierunek domyślny.
        guard n > 0, best.l > 245, best.l > sum / n * 1.35 else { return fallback }
        let u = (Float(best.x) + 0.5) / Float(w), v = (Float(best.y) + 0.5) / Float(h)
        let phi = (u - 0.5) * 2 * .pi
        // Wysokość słońca w granicach 25–65°: niżej cienie byłyby za długie, wyżej znikają pod autami.
        let theta = min(65, max(25, (0.5 - v) * 180)) * .pi / 180
        let dir = SIMD3<Float>(sin(phi) * cos(theta), sin(theta), -cos(phi) * cos(theta))
        // Barwa: średnia wokół słońca, odbarwiona do lekkiego odcienia (ciepłe popołudnie, chłodny poranek).
        var c = SIMD3<Float>(repeating: 0), m: Float = 0
        for dy in -6...6 {
            for dx in -6...6 {
                let x = (best.x + dx + w) % w, y = min(h - 1, max(0, best.y + dy))
                let p = data + (y * w + x) * 4
                c += SIMD3(Float(p[0]), Float(p[1]), Float(p[2])); m += 1
            }
        }
        c /= m * 255
        let tint = simd_mix(SIMD3<Float>(repeating: 1), c / max(c.x, max(c.y, c.z)), SIMD3(repeating: 0.35))
        return SunEstimate(direction: simd_normalize(dir), color: UIColor(red: CGFloat(tint.x), green: CGFloat(tint.y),
                                                                        blue: CGFloat(tint.z), alpha: 1), fromPhoto: true)
    }
}
