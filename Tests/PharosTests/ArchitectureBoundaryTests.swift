import Foundation
import XCTest
import PharosClientKit

final class ArchitectureBoundaryTests: XCTestCase {
    /// Phase E: Swift backend modules must be gone (not merely unlinked).
    private let removedBackendDirectories = [
        "Sources/PharosMeshProtocol",
        "Sources/PharosMeshIdentity",
        "Sources/PharosMeshIroh",
        "Sources/PharosMeshReplica",
        "Sources/PharosMeshControl",
        "Sources/PharosMeshLifecycle",
        "Sources/PharosMeshCore",
        "Sources/PharosAgentCore",
        "Sources/PharosRuntime",
        "Sources/PharosCodexAdapter",
        "Sources/PharosMesh",
        "Sources/CSQLite",
    ]

    func testRemovedBackendModulesDoNotExistOnDisk() {
        for directory in removedBackendDirectories {
            let url = repositoryRoot.appendingPathComponent(directory)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "Phase E must remove \(directory)"
            )
        }
    }

    func testPackageSwiftDoesNotDeclareMeshOrRuntimeTargets() throws {
        let url = repositoryRoot.appendingPathComponent("Package.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let forbidden = [
            "PharosMeshCore",
            "PharosRuntime",
            "PharosMeshProtocol",
            "PharosMeshIdentity",
            "PharosMeshIroh",
            "PharosMeshReplica",
            "PharosMeshLifecycle",
            "PharosMeshControl",
            "PharosCodexAdapter",
            "PharosAgentCore",
            "CSQLite",
            "MeshKit",
            "desktop-mesh",
        ]
        for token in forbidden {
            XCTAssertFalse(source.contains(token), "Package.swift still mentions \(token)")
        }
        XCTAssertTrue(source.contains("PharosClientKit"))
        XCTAssertTrue(source.contains("\"Pharos\""))
    }

    func testClientKitAndAppSourcesDoNotImportRemovedModules() throws {
        let forbiddenImports = [
            "import PharosMeshCore",
            "import PharosRuntime",
            "import PharosMeshProtocol",
            "import PharosMeshIdentity",
            "import PharosMeshIroh",
            "import PharosMeshReplica",
            "import PharosMeshLifecycle",
            "import PharosMeshControl",
            "import PharosCodexAdapter",
            "import PharosAgentCore",
        ]
        let roots = [
            "Sources/PharosClientKit",
            "Sources/Pharos",
        ]
        for root in roots {
            let dir = repositoryRoot.appendingPathComponent(root)
            for file in try swiftFiles(in: dir) {
                let source = try String(contentsOf: file, encoding: .utf8)
                let relative = file.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
                for token in forbiddenImports {
                    XCTAssertFalse(source.contains(token), "\(relative) contains \(token)")
                }
            }
        }
    }

    func testRustAPIIsOnlyClientBackend() {
        let suite = "pharos.arch.boundary.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(
            PharosClientBackendKind.resolve(environment: [:], defaults: defaults),
            .rustAPI
        )
        XCTAssertEqual(
            PharosClientBackendKind.resolve(
                environment: ["PHAROS_CLIENT_BACKEND": "desktop-mesh"],
                defaults: defaults
            ),
            .rustAPI
        )
        XCTAssertEqual(PharosClientBackendKind.rustAPI.rawValue, "rust-api")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return [] }
        return try enumerator.compactMap { element in
            guard let url = element as? URL,
                  url.pathExtension == "swift",
                  try url.resourceValues(forKeys: Set(keys)).isRegularFile == true else { return nil }
            return url
        }
    }
}
