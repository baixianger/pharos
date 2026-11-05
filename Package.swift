// swift-tools-version: 6.2
import PackageDescription

// The app test target imports SwiftUI. Linux builds the lightweight tier only;
// macOS still runs the full suite. `#if` cannot sit inside the Package literal.
let packageTargets: [Target] = {
    var targets: [Target] = [
        .systemLibrary(
            name: "CSQLite",
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
            name: "PharosClientKit",
            path: "Sources/PharosClientKit"
        ),
        .target(
            name: "PharosMeshIroh",
            dependencies: [
                "PharosMeshProtocol",
                .product(name: "MeshKit", package: "MeshKit"),
                .product(name: "MeshKitIroh", package: "MeshKit"),
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
            name: "PharosMeshReplica",
            dependencies: [
                "PharosMeshProtocol",
                "PharosMeshIdentity",
                "CSQLite",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/PharosMeshReplica"
        ),
        .target(
            name: "PharosMeshControl",
            dependencies: [
                "PharosMeshProtocol",
                "PharosMeshIdentity",
                "PharosMeshIroh",
                "PharosMeshReplica",
            ],
            path: "Sources/PharosMeshControl"
        ),
        .target(
            name: "PharosMeshLifecycle",
            dependencies: [
                "PharosMeshProtocol",
                "PharosMeshIdentity",
                "PharosMeshIroh",
                "PharosMeshReplica",
            ],
            path: "Sources/PharosMeshLifecycle"
        ),
        .target(
            name: "PharosMeshCore",
            dependencies: [
                "PharosMeshProtocol",
                "PharosMeshIdentity",
                "PharosMeshIroh",
                "PharosMeshReplica",
                "PharosMeshControl",
                "PharosMeshLifecycle",
                "CSQLite",
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
            name: "PharosMesh",
            dependencies: [
                "PharosMeshCore",
                "PharosAgentCore",
                "PharosRuntime",
                "PharosCodexAdapter",
                "PharosMeshLifecycle",
            ],
            path: "Sources/PharosMesh"
        ),
        .testTarget(
            name: "PharosLightTests",
            dependencies: ["PharosMeshCore", "PharosRuntime"],
            path: "Tests/PharosLightTests"
        ),
        .testTarget(
            name: "PharosMeshProtocolTests",
            dependencies: ["PharosMeshProtocol"],
            path: "Tests/PharosMeshProtocolTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PharosMeshIrohTests",
            dependencies: [
                "PharosMeshIroh",
                "PharosMeshIdentity",
                "PharosMeshLifecycle",
                "PharosMeshReplica",
            ],
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
    #if os(macOS)
    targets.append(
        .executableTarget(
            name: "Pharos",
            dependencies: [
                "PharosClientKit",
                "PharosMeshCore",
                "PharosRuntime",
                "PharosMeshLifecycle",
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
        )
    )
    targets.append(
        .testTarget(
            name: "PharosTests",
            dependencies: [
                "Pharos",
                "PharosClientKit",
                "PharosMeshCore",
                "PharosAgentCore",
                "PharosRuntime",
                "PharosCodexAdapter",
                "PharosMeshLifecycle",
            ],
            path: "Tests/PharosTests",
            resources: [.copy("Fixtures")]
        )
    )
    #endif
    return targets
}()

let packageProducts: [Product] = {
    var products: [Product] = [
        .executable(name: "pharos-mesh", targets: ["PharosMesh"]),
        .library(name: "PharosClientKit", targets: ["PharosClientKit"]),
        .library(name: "PharosMeshProtocol", targets: ["PharosMeshProtocol"]),
        .library(name: "PharosMeshIdentity", targets: ["PharosMeshIdentity"]),
        .library(name: "PharosMeshIroh", targets: ["PharosMeshIroh"]),
        .library(name: "PharosMeshReplica", targets: ["PharosMeshReplica"]),
        .library(name: "PharosMeshControl", targets: ["PharosMeshControl"]),
        .library(name: "PharosMeshLifecycle", targets: ["PharosMeshLifecycle"]),
        .library(name: "PharosMeshCore", targets: ["PharosMeshCore"]),
        .library(name: "PharosAgentCore", targets: ["PharosAgentCore"]),
        .library(name: "PharosRuntime", targets: ["PharosRuntime"]),
        .library(name: "PharosCodexAdapter", targets: ["PharosCodexAdapter"]),
    ]
    #if os(macOS)
    products.insert(.executable(name: "Pharos", targets: ["Pharos"]), at: 0)
    #endif
    return products
}()

let packageDependencies: [Package.Dependency] = {
    var dependencies: [Package.Dependency] = [
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
        .package(
            url: "https://github.com/baixianger/MeshKit.git",
            exact: "0.2.1"
        ),
    ]
    #if os(macOS)
    dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"))
    #endif
    return dependencies
}()

let package = Package(
    name: "Pharos",
    platforms: [
        .macOS(.v26), // Liquid Glass requires macOS 26 (Tahoe)
        .iOS(.v26),
    ],
    products: packageProducts,
    dependencies: packageDependencies,
    targets: packageTargets
)
