import Foundation
import XCTest
@testable import PharosMeshCore

final class DistributedHookCLITests: XCTestCase {
    func testExactPaneAndSocketWinsWhenCWDIsShared() throws {
        let root = try makeRoot(sessions: [
            "session-old": observation(cwd: "/workspace", pane: "%1", socket: "/tmp/tmux-a", updatedAt: 20),
            "session-exact": observation(cwd: "/workspace", pane: "%2", socket: "/tmp/tmux-b", updatedAt: 10),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            DistributedHookCLI.currentSessionID(
                environment: ["TMUX_PANE": "%2", "TMUX": "/tmp/tmux-b,123,0"],
                rootURL: root,
                currentDirectory: "/workspace"
            ),
            "session-exact"
        )
    }

    func testCWDFallbackRequiresOneLiveMatch() throws {
        let root = try makeRoot(sessions: [
            "session-live": observation(cwd: "/one", updatedAt: 10),
            "session-gone": observation(cwd: "/one", state: "gone", updatedAt: 20),
            "session-other": observation(cwd: "/two", updatedAt: 30),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            DistributedHookCLI.currentSessionID(
                environment: [:], rootURL: root, currentDirectory: "/one"
            ),
            "session-live"
        )

        let ambiguous = try makeRoot(sessions: [
            "session-a": observation(cwd: "/shared", updatedAt: 10),
            "session-b": observation(cwd: "/shared", updatedAt: 20),
        ])
        defer { try? FileManager.default.removeItem(at: ambiguous) }
        XCTAssertNil(
            DistributedHookCLI.currentSessionID(
                environment: [:], rootURL: ambiguous, currentDirectory: "/shared"
            )
        )
    }

    private func makeRoot(sessions: [String: [String: Any]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-hook-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let document: [String: Any] = ["version": 1, "sessions": sessions]
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(
            to: root.appendingPathComponent("agent-host-observations-v1.json"),
            options: .atomic
        )
        return root
    }

    private func observation(
        cwd: String, pane: String? = nil, socket: String? = nil,
        state: String = "present", updatedAt: Double
    ) -> [String: Any] {
        var value: [String: Any] = [
            "cwd": cwd, "state": state, "updatedAt": updatedAt,
        ]
        if let pane { value["tmuxPane"] = pane }
        if let socket { value["tmuxSocket"] = socket }
        return value
    }
}
