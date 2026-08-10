import Foundation
import XCTest

final class ArchitectureBoundaryTests: XCTestCase {
    func testCoreModulesDoNotImportPresentationFrameworks() throws {
        for directory in ["Sources/PharosMeshCore", "Sources/PharosRuntime"] {
            for file in try swiftFiles(in: repositoryRoot.appendingPathComponent(directory)) {
                let source = try String(contentsOf: file, encoding: .utf8)
                XCTAssertFalse(source.contains("import SwiftUI"), "\(file.path) imports SwiftUI")
                XCTAssertFalse(source.contains("import AppKit"), "\(file.path) imports AppKit")
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
