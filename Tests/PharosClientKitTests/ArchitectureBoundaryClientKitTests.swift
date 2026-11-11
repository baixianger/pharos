import Foundation
import XCTest
@testable import PharosClientKit

/// S6 / RFC-007 Phase D boundary gates that run without linking MeshCore/Runtime.
/// Complements `Tests/PharosTests/ArchitectureBoundaryTests` (blocked on tip Mesh build).
final class ArchitectureBoundaryClientKitTests: XCTestCase {
    func testClientKitSourcesDoNotImportMeshOrRuntime() throws {
        let forbidden = [
            "import PharosMeshCore",
            "import PharosRuntime",
            "import PharosMeshProtocol",
            "import PharosMeshIdentity",
            "import PharosMeshIroh",
            "import PharosMeshReplica",
            "import PharosMeshLifecycle",
            "import PharosMeshControl",
            "import PharosCodexAdapter",
            "import SwiftUI",
            "import AppKit",
            "import Cocoa",
        ]
        let root = repositoryRoot.appendingPathComponent("Sources/PharosClientKit")
        for file in try swiftFiles(in: root) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(
                    source.contains(token),
                    "\(file.lastPathComponent) must not contain '\(token)'"
                )
            }
        }
    }

    func testHttpClientExistsAndDefaultBackendIsRustAPI() {
        XCTAssertEqual(PharosAPIConfiguration.contractsVersion, "0.1.0")
        let suite = "pharos.clientkit.boundary.\(UUID().uuidString)"
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
        let client = HttpPharosClientService(
            configuration: PharosAPIConfiguration(
                baseURL: URL(string: "http://127.0.0.1:8787")!,
                backendKind: .rustAPI
            )
        )
        // Actor materializes; proves the HTTP path type is linked from ClientKit alone.
        _ = client
    }

    func testRustAPIUIPathSourcesDoNotImportMeshOrRuntime() throws {
        let forbidden = [
            "import PharosMeshCore",
            "import PharosRuntime",
        ]
        let paths = [
            "Sources/Pharos/UI/Shell/PharosClientBackend.swift",
            "Sources/Pharos/UI/Canvas/PharosWebCanvasView.swift",
            "Sources/Pharos/UI/Shell/PharosMainShellView.swift",
            "Sources/Pharos/UI/Canvas/ConversationCanvasView.swift",
            "Sources/Pharos/UI/Canvas/SessionConversationViewModel.swift",
            "Sources/Pharos/UI/Canvas/ThreadConversationViewModel.swift",
        ]
        for relative in paths {
            let url = repositoryRoot.appendingPathComponent(relative)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing \(relative)")
            let source = try String(contentsOf: url, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(source.contains(token), "\(relative) contains \(token)")
            }
        }
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
