// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ducko",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Ducko", targets: ["DuckoApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "DuckoXMPP"),
        .testTarget(name: "DuckoXMPPTests", dependencies: ["DuckoXMPP"]),

        .target(name: "DuckoCore", dependencies: ["DuckoXMPP"]),
        .testTarget(name: "DuckoCoreTests", dependencies: ["DuckoCore"]),

        .target(name: "DuckoData", dependencies: ["DuckoCore"]),
        .testTarget(name: "DuckoDataTests", dependencies: ["DuckoData"]),

        .target(name: "DuckoUI", dependencies: ["DuckoCore"]),
        .testTarget(name: "DuckoUITests", dependencies: ["DuckoUI"]),

        .executableTarget(
            name: "DuckoApp",
            dependencies: ["DuckoCore", "DuckoData", "DuckoUI", "DuckoXMPP", "Sparkle"]
        ),
    ]
)
