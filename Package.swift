// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pharos",
    platforms: [
        .macOS(.v26), // Liquid Glass requires macOS 26 (Tahoe)
    ],
    products: [
        .executable(name: "Pharos", targets: ["Pharos"]),
        .executable(name: "pharos-mesh", targets: ["PharosMesh"]),
        .library(name: "PharosMeshCore", targets: ["PharosMeshCore"]),
        .library(name: "PharosAgentCore", targets: ["PharosAgentCore"]),
        .library(name: "PharosRuntime", targets: ["PharosRuntime"]),
        .library(name: "PharosCodexAdapter", targets: ["PharosCodexAdapter"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "PharosMeshCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/PharosMeshCore"
        ),
        .target(name: "PharosAgentCore", path: "Sources/PharosAgentCore"),
        .target(
            name: "PharosRuntime",
            dependencies: ["PharosMeshCore", "PharosAgentCore"],
            path: "Sources/PharosRuntime"
        ),
        .target(
            name: "PharosCodexAdapter",
            dependencies: ["PharosAgentCore"],
            path: "Sources/PharosCodexAdapter"
        ),
        .executableTarget(
            name: "Pharos",
            dependencies: [
                "PharosMeshCore",
                "PharosRuntime",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Pharos",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                // Phase 0: relax strict concurrency to keep the scaffold building.
                // Tighten to .v6 once the service layer is finalized.
                // TODO: tighten to Swift 6 strict concurrency — blocked on Sparkle's
                // KVO keypath for `canCheckForUpdates` being main-actor isolated
                // (Updater.swift line 60). One error in Swift 6 mode.
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "PharosMesh",
            dependencies: ["PharosMeshCore", "PharosAgentCore", "PharosRuntime", "PharosCodexAdapter"],
            path: "Sources/PharosMesh"
        ),
        .testTarget(
            name: "PharosTests",
            dependencies: [
                "Pharos", "PharosMeshCore", "PharosAgentCore",
                "PharosRuntime", "PharosCodexAdapter",
            ],
            path: "Tests/PharosTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
