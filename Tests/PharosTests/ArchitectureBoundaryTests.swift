import Foundation
import XCTest
import PharosClientKit

final class ArchitectureBoundaryTests: XCTestCase {
    private let backendDirectories = [
        "Sources/PharosClientKit",
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
    ]

    func testCoreModulesDoNotImportPresentationFrameworks() throws {
        let forbiddenImports = ["import SwiftUI", "import AppKit", "import Cocoa"]
        for directory in backendDirectories {
            let dirURL = repositoryRoot.appendingPathComponent(directory)
            guard FileManager.default.fileExists(atPath: dirURL.path) else { continue }
            for file in try swiftFiles(in: dirURL) {
                let source = try String(contentsOf: file, encoding: .utf8)
                for forbidden in forbiddenImports {
                    XCTAssertFalse(
                        source.contains(forbidden),
                        "\(file.path) imports presentation framework '\(forbidden)' in backend module"
                    )
                }
            }
        }
    }

    func testBackendModulesDoNotImportAppTarget() throws {
        for directory in backendDirectories {
            let dirURL = repositoryRoot.appendingPathComponent(directory)
            guard FileManager.default.fileExists(atPath: dirURL.path) else { continue }
            for file in try swiftFiles(in: dirURL) {
                let source = try String(contentsOf: file, encoding: .utf8)
                XCTAssertFalse(
                    source.contains("import Pharos\n") || source.contains("import Pharos;"),
                    "\(file.path) imports presentation target 'Pharos' in backend module"
                )
            }
        }
    }

    func testPresentationDoesNotManageRuntimeProcesses() throws {
        let directory = repositoryRoot.appendingPathComponent("Sources/Pharos")
        let forbidden = ["launchctl", "Library/LaunchAgents", "node\", \"install", "serve\", \"--bind"]
        for file in try swiftFiles(in: directory) {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains("import SwiftUI") else { continue }
            for token in forbidden {
                XCTAssertFalse(source.contains(token), "\(file.path) contains runtime detail '\(token)'")
            }
        }
    }

    /// RFC-007 Phase D / S6: the rust-api client path must not import MeshCore or Runtime.
    /// Full Package.swift unlink of MeshCore/Runtime from the app target is captain / Phase E;
    /// this gate asserts the new-path sources themselves stay mesh-free.
    func testRustAPIClientPathDoesNotImportMeshOrRuntime() throws {
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
        ]
        let newPathRoots = [
            "Sources/PharosClientKit",
            "Sources/Pharos/UI/Shell/PharosClientBackend.swift",
            "Sources/Pharos/UI/Canvas/PharosWebCanvasView.swift",
            "Sources/Pharos/UI/Shell/PharosMainShellView.swift",
            "Sources/Pharos/UI/Canvas/ConversationCanvasView.swift",
            "Sources/Pharos/UI/Canvas/SessionConversationViewModel.swift",
            "Sources/Pharos/UI/Canvas/ThreadConversationViewModel.swift",
        ]
        // Legacy desktop-mesh implementation may still import Mesh/Runtime (kept until Phase E).
        let legacyAllowlist = Set([
            "Sources/Pharos/UI/Shell/DesktopPharosClientService.swift",
        ])

        for root in newPathRoots {
            let url = repositoryRoot.appendingPathComponent(root)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                XCTFail("Missing rust-api path file/dir: \(root)")
                continue
            }
            let files: [URL]
            if isDir.boolValue {
                files = try swiftFiles(in: url)
            } else {
                files = [url]
            }
            for file in files {
                let relative = file.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
                if legacyAllowlist.contains(relative) { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                for forbidden in forbiddenImports {
                    XCTAssertFalse(
                        source.contains(forbidden),
                        "\(relative) imports '\(forbidden)' on the rust-api client path"
                    )
                }
            }
        }
    }

    /// Assert ClientKit HTTP impl exists and is the default backend kind.
    func testRustAPIIsDefaultClientBackend() {
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
            .desktopMesh
        )
        XCTAssertEqual(PharosClientBackendKind.rustAPI.rawValue, "rust-api")
        XCTAssertEqual(PharosClientBackendKind.desktopMesh.rawValue, "desktop-mesh")
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
