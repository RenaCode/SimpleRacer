// swift-tools-version:6.0
import PackageDescription

// Logika gry bez grafiki. Aplikacja na iPada (App/, project.yml) używa jej jako lokalnego pakietu,
// a testy działają na macOS przez `swift test`, bez symulatora.
let package = Package(
    name: "RaceCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "RaceCore", targets: ["RaceCore"])],
    targets: [
        .target(name: "RaceCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "RaceCoreTests", dependencies: ["RaceCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
