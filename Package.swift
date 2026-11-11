// swift-tools-version: 6.2
import PackageDescription

// Phase E (RFC-007): client-only Swift package.
// Former Swift backend targets were removed; the app talks to the Rust daemon
// via PharosClientKit HTTP/WS only.

let packageTargets: [Target] = {
    var targets: [Target] = [
        .target(
            name: "PharosClientKit",
            path: "Sources/PharosClientKit"
        ),
        .testTarget(
            name: "PharosClientKitTests",
            dependencies: ["PharosClientKit"],
            path: "Tests/PharosClientKitTests"
        ),
    ]
    #if os(macOS)
    targets.append(
        .executableTarget(
            name: "Pharos",
            dependencies: [
                "PharosClientKit",
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
        .library(name: "PharosClientKit", targets: ["PharosClientKit"]),
    ]
    #if os(macOS)
    products.insert(.executable(name: "Pharos", targets: ["Pharos"]), at: 0)
    #endif
    return products
}()

let packageDependencies: [Package.Dependency] = {
    var dependencies: [Package.Dependency] = []
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
