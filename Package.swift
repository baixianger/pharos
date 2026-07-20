// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pharos",
    platforms: [
        .macOS(.v26), // Liquid Glass requires macOS 26 (Tahoe)
        .iOS(.v26),
    ],
    products: [
        .executable(name: "Pharos", targets: ["Pharos"]),
        .executable(name: "pharos-mesh", targets: ["PharosMesh"]),
        .library(name: "PharosMeshProtocol", targets: ["PharosMeshProtocol"]),
        .library(name: "PharosMeshIdentity", targets: ["PharosMeshIdentity"]),
        .library(name: "PharosMeshIroh", targets: ["PharosMeshIroh"]),
        .library(name: "PharosMeshCore", targets: ["PharosMeshCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
        .package(url: "https://github.com/n0-computer/iroh-ffi", exact: "1.1.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"]),
                .brew(["sqlite3"]),
            ]
        ),
        .target(
            name: "PharosMeshProtocol",
            path: "Sources/PharosMeshProtocol"
        ),
        .target(
            name: "PharosMeshIroh",
            dependencies: [
                "PharosMeshProtocol",
                .product(
                    name: "IrohLib",
                    package: "iroh-ffi",
                    condition: .when(platforms: [.macOS, .iOS])
                ),
            ],
            path: "Sources/PharosMeshIroh"
        ),
        .target(
            name: "PharosMeshIdentity",
            dependencies: [
                "PharosMeshProtocol",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/PharosMeshIdentity"
        ),
        .target(
            name: "PharosMeshCore",
            dependencies: [
                "PharosMeshProtocol",
                "PharosMeshIdentity",
                "PharosMeshIroh",
                "CSQLite",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/PharosMeshCore"
        ),
        .executableTarget(
            name: "Pharos",
            dependencies: [
                "PharosMeshCore",
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
            dependencies: ["PharosMeshCore"],
            path: "Sources/PharosMesh"
        ),
        .testTarget(
            name: "PharosTests",
            dependencies: ["Pharos"],
            path: "Tests/PharosTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PharosMeshProtocolTests",
            dependencies: ["PharosMeshProtocol"],
            path: "Tests/PharosMeshProtocolTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PharosMeshIrohTests",
            dependencies: ["PharosMeshIroh", "PharosMeshIdentity"],
            path: "Tests/PharosMeshIrohTests"
        ),
        .testTarget(
            name: "PharosMeshIdentityTests",
            dependencies: [
                "PharosMeshIdentity",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Tests/PharosMeshIdentityTests"
        ),
        .testTarget(
            name: "PharosMeshCoreTests",
            dependencies: ["PharosMeshCore", "PharosMeshIdentity", "CSQLite"],
            path: "Tests/PharosMeshCoreTests"
        ),
    ]
)
