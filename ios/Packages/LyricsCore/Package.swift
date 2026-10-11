// swift-tools-version: 6.0
// LyricsCore — the platform-free core of LyricsTranslator (SSRD PR-5, Win-AGRE-3).
// No UI imports, no third-party dependencies. Builds on Apple platforms and Linux.
import PackageDescription

let package = Package(
    name: "LyricsCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LyricsCore", targets: ["LyricsCore"]),
    ],
    targets: [
        .target(
            name: "LyricsCore",
            resources: [.process("Curation/Resources")]
        ),
        .testTarget(
            name: "LyricsCoreTests",
            dependencies: ["LyricsCore"]
        ),
    ]
)
