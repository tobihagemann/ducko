// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DuckoIntegrationTests",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(name: "Ducko", path: "..")
    ],
    targets: [
        .testTarget(
            name: "DuckoIntegrationTests",
            dependencies: [
                .product(name: "DuckoCore", package: "Ducko"),
                .product(name: "DuckoData", package: "Ducko"),
                .product(name: "DuckoXMPP", package: "Ducko")
            ]
        )
    ]
)
