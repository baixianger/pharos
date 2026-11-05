import Foundation
import XCTest

final class ArchitectureBoundaryTests: XCTestCase {
    private let backendDirectories = [
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
