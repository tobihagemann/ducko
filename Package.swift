// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ducko",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "DuckoApp", targets: ["DuckoApp"]),
        .executable(name: "DuckoCLI", targets: ["DuckoCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .systemLibrary(name: "CLibxml2", path: "Sources/CLibxml2", pkgConfig: "libxml-2.0"),

        .target(name: "DuckoXMPP", dependencies: ["CLibxml2"]),
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

        .executableTarget(
            name: "DuckoCLI",
            dependencies: [
                "DuckoCore",
                "DuckoData",
                "DuckoXMPP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "DuckoCLITests", dependencies: ["DuckoCLI"]),
    ]
)
