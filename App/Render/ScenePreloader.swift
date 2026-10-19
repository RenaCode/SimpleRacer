import ImageIO
import RaceCore
import RealityKit
import UIKit

/// Wczytywanie ciężkich tekstur w tle, jak w silnikach gier: obraz dekoduje się poza głównym wątkiem,
/// teksturę tworzy RealityKit po jednej na klatkę, a budowa sceny bierze gotowe tekstury z pamięci.
/// Dzięki temu ekran ładowania płynnie się animuje, zamiast zamarzać, a menu może z góry przygotować
/// krainę następnej trasy („Ścigaj się” rusza prawie od razu).
///
/// W pamięci trzymamy garaż i jedną krainę naraz — przygotowanie innej krainy zwalnia poprzednią.
@MainActor
@Observable
final class ScenePreloader {
    static let shared = ScenePreloader()

    /// Postęp ostatnio przygotowywanej grupy (0…1) — do paska na ekranie ładowania.
    private(set) var progress = 0.0

    @ObservationIgnored private var textures: [String: TextureResource] = [:]
    @ObservationIgnored private var groupPaths: [String: [String]] = [:]
    @ObservationIgnored private var ready: Set<String> = []
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]

    struct Job: Sendable {
        let url: URL
        /// Obraz z przezroczystością: dodatkowo maska z kanału alfa (tekstura nieprzezroczystości czyta kanał R).
        let mask: Bool
    }

    func texture(_ url: URL) -> TextureResource? { textures[url.path] }
    func mask(_ url: URL) -> TextureResource? { textures[url.path + "#mask"] }
    func isReady(_ region: Region) -> Bool { ready.contains(Self.group(region)) }

    func prepare(_ region: Region) async {
        let group = Self.group(region)
        // Inne krainy zwalniamy (pamięć iPada); materiały impostorów trzymają ich tekstury.
        for other in groupPaths.keys where other.hasPrefix("region-") && other != group {
            for path in groupPaths[other] ?? [] { textures[path] = nil; textures[path + "#mask"] = nil }
            groupPaths[other] = nil
            ready.remove(other)
            ImpostorLibrary.shared.purge()
            Buildings.purge()
        }
        await prepare(group: group, jobs: Self.jobs(for: region))
    }

    func prepareGarage() async {
        let floor = Bundle.main.url(forResource: "floor-garage", withExtension: "jpg").map { Job(url: $0, mask: false) }
        await prepare(group: "garage", jobs: Self.skyJobs("garage") + [floor].compactMap { $0 })
    }

    private func prepare(group: String, jobs: [Job]) async {
        if ready.contains(group) { progress = 1; return }
        if let running = inFlight[group] { await running.value; return }
        let task = Task { @MainActor in
            progress = 0
            let start = ProcessInfo.processInfo.systemUptime
            for (i, job) in jobs.enumerated() where !Task.isCancelled {
                if textures[job.url.path] == nil {
                    let decoded = await Task.detached(priority: .userInitiated) { Self.decode(job) }.value
                    if let image = decoded.image {
                        let semantic: TextureResource.Semantic = Self.isRaw(job.url) ? .raw : .color
                        // Synchronicznie, po jednej teksturze na klatkę: asynchroniczne tworzenie tekstur
                        // w RealityKit co kilka uruchomień psuło cały proces (żaden model się nie wczytywał).
                        textures[job.url.path] = Self.makeTexture(image, semantic: semantic)
                        await Task.yield()
                    }
                    if let mask = decoded.mask {
                        textures[job.url.path + "#mask"] = Self.makeTexture(mask, semantic: .raw)
                        await Task.yield()
                    }
                }
                progress = Double(i + 1) / Double(jobs.count)
            }
            groupPaths[group] = jobs.map(\.url.path)
            ready.insert(group)
            debugLog(String(format: "wczytywanie: %@ — %d tekstur w %.2f s", group, jobs.count,
                            ProcessInfo.processInfo.systemUptime - start))
        }
        inFlight[group] = task
        await task.value
        inFlight[group] = nil
    }

    /// Zwykła (synchroniczna) funkcja, żeby kompilator wybrał synchroniczny konstruktor tekstury.
    private static func makeTexture(_ image: CGImage, semantic: TextureResource.Semantic) -> TextureResource? {
        try? TextureResource(image: image, options: .init(semantic: semantic, mipmapsMode: .allocateAndGenerateAll))
    }

    // MARK: - Co wczytać

    /// Mapy danych (normalne, chropowatość) — bez konwersji kolorów sRGB.
    nonisolated static func isRaw(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        return name.hasSuffix("-normal") || name.hasSuffix("-rough") || name.hasSuffix("-metal")
    }

    private static func group(_ region: Region) -> String { "region-" + LocalAssets.regionKey(region) }

    private static func skyJobs(_ name: String) -> [Job] {
        ["sky-\(name)", "sky-\(name)-band"].compactMap { Bundle.main.url(forResource: $0, withExtension: "jpg") }
            .map { Job(url: $0, mask: false) }
    }

    private static func jobs(for region: Region) -> [Job] {
        let key = LocalAssets.regionKey(region)
        var jobs = skyJobs(key)
        jobs += ["ground-\(key)", "wall-\(key)", "road-asphalt", "road-paint", "kerb", "start-line"].compactMap { Bundle.main.url(forResource: $0, withExtension: "jpg") }
            .map { Job(url: $0, mask: false) }
        // Mapy normalnych i chropowatości to dane, nie kolor — `semantic: .raw` (patrz `rawNames`).
        jobs += ["road-asphalt-normal", "road-asphalt-rough", "wall-\(key)-normal", "kerb-normal", "props-steel", "props-steel-normal", "props-steel-rough"].compactMap { Bundle.main.url(forResource: $0, withExtension: "jpg") }
            .map { Job(url: $0, mask: false) }
        if TrackTheme.of(region).buildings > 0 {
            jobs += Buildings.textureNames.compactMap { Bundle.main.url(forResource: $0, withExtension: "jpg") }
                .map { Job(url: $0, mask: false) }
        }
        let library = ImpostorLibrary.shared
        for kind in ["building", "tree", "bush"] {
            for item in library.items(kind, region: region) {
                jobs.append(Job(url: item.front, mask: true))
                jobs.append(Job(url: item.side, mask: true))
            }
        }
        var seen = Set<String>()
        return jobs.filter { seen.insert($0.url.path).inserted }
    }

    // MARK: - Dekodowanie (poza głównym wątkiem)

    struct Decoded: @unchecked Sendable {
        let image: CGImage?
        let mask: CGImage?
    }

    nonisolated static func decode(_ job: Job) -> Decoded {
        guard let source = CGImageSourceCreateWithURL(job.url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return Decoded(image: nil, mask: nil) }
        return Decoded(image: image, mask: job.mask ? alphaMask(image) : nil)
    }

    /// Kanał alfa obrazu jako obraz w odcieniach szarości (białe = widoczne).
    nonisolated static func alphaMask(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let provider = CGDataProvider(data: Data(bytes: data, count: w * h) as CFData)
        return provider.flatMap {
            CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                    provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }
}
