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
                environment: [:], rootURL: root, currentDirectory: "/one",
                now: 35
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
                environment: [:], rootURL: ambiguous, currentDirectory: "/shared",
                now: 35
            )
        )
    }

    func testCWDFallbackRejectsStaleUnboundGhost() throws {
        let root = try makeRoot(sessions: [
            "session-ghost": observation(cwd: "/workspace", updatedAt: 10),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(DistributedHookCLI.currentSessionID(
            environment: [:], rootURL: root,
            currentDirectory: "/workspace", now: 500
        ))
    }

    func testLocalPresenceLoadsStructuredStateAndKind() throws {
        let root = try makeRoot(sessions: [
            "session-live": observation(
                cwd: "/workspace", pane: "%4", socket: "/tmp/tmux-live",
                state: "busy", updatedAt: 42, kind: "codex"
            ),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let presence = DistributedHookCLI.localAgentPresence(rootURL: root)
        XCTAssertEqual(presence["session-live"]?.state, "busy")
        XCTAssertEqual(presence["session-live"]?.tmuxPane, "%4")
        XCTAssertEqual(presence["session-live"]?.kind, "codex")
    }

    func testRecordingKindUpdatesExistingHookObservation() throws {
        let root = try makeRoot(sessions: [
            "session-live": observation(cwd: "/workspace", updatedAt: 42),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        try DistributedHookCLI.recordLocalAgentKind(
            "claude", memberID: "session-live", rootURL: root
        )
        XCTAssertEqual(
            DistributedHookCLI.localAgentPresence(rootURL: root)["session-live"]?.kind,
            "claude"
        )
    }

    func testClearRebindRequiresExactRecentSeatAndCWD() throws {
        let root = try makeRoot(sessions: [
            "session-exact": observation(
                cwd: "/workspace", pane: "%4", socket: "/tmp/tmux-live",
                updatedAt: 900
            ),
            "session-other-pane": observation(
                cwd: "/workspace", pane: "%5", socket: "/tmp/tmux-live",
                updatedAt: 950
            ),
            "session-other-project": observation(
                cwd: "/other", pane: "%4", socket: "/tmp/tmux-live",
                updatedAt: 975
            ),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["TMUX_PANE": "%4", "TMUX": "/tmp/tmux-live,123,0"]

        XCTAssertEqual(
            DistributedHookCLI.rebindCandidate(
                sessionID: "session-new", source: "clear",
                payload: ["cwd": "/workspace"], environment: environment,
                rootURL: root, now: 1_000
            ),
            "session-exact"
        )
        XCTAssertNil(DistributedHookCLI.rebindCandidate(
            sessionID: "session-new", source: "startup",
            payload: ["cwd": "/workspace"], environment: environment,
            rootURL: root, now: 1_000
        ))
        XCTAssertNil(DistributedHookCLI.rebindCandidate(
            sessionID: "session-new", source: "resume",
            payload: ["cwd": "/workspace"], environment: environment,
            rootURL: root, now: 3_000
        ))
    }

    func testDeliveryHooksPersistBusyAndIdleTurnBoundaries() throws {
        let root = try makeRoot(sessions: [:])
        defer { try? FileManager.default.removeItem(at: root) }

        try DistributedHookCLI.persistObservation(
            mode: "post-tool",
            payload: ["hook_event_name": "PostToolUse", "cwd": "/workspace"],
            session: "session-live", root: root
        )
        XCTAssertEqual(
            DistributedHookCLI.localAgentPresence(rootURL: root)["session-live"]?.state,
            "busy"
        )
        try DistributedHookCLI.persistObservation(
            mode: "stop",
            payload: ["hook_event_name": "Stop", "cwd": "/workspace"],
            session: "session-live", root: root
        )
        let idle = DistributedHookCLI.localAgentPresence(rootURL: root)["session-live"]
        XCTAssertEqual(idle?.state, "idle")
        XCTAssertEqual(idle?.event, "Stop")
        XCTAssertEqual(idle?.mode, "stop")
    }

    func testLifecycleMappingMatchesClearIdleAndBlockingSemantics() throws {
        let root = try makeRoot(sessions: [:])
        defer { try? FileManager.default.removeItem(at: root) }
        func record(_ event: String, _ values: [String: Any] = [:]) throws
            -> DistributedHookCLI.LocalAgentPresence? {
            var payload = values
            payload["hook_event_name"] = event
            payload["cwd"] = "/workspace"
            try DistributedHookCLI.persistObservation(
                mode: "mark", payload: payload,
                session: "session-live", root: root
            )
            return DistributedHookCLI.localAgentPresence(rootURL: root)["session-live"]
        }

        XCTAssertEqual(try record("SessionEnd", ["reason": "clear"])?.state, "stopped")
        XCTAssertEqual(try record("SessionStart")?.state, "busy")
        XCTAssertEqual(try record("PreToolUse")?.state, "blocked")
        XCTAssertEqual(try record("PreToolUse")?.reason, "form")
        let permission = try record(
            "Notification", ["notification_type": "permission_prompt"]
        )
        XCTAssertEqual(permission?.state, "blocked")
        XCTAssertEqual(permission?.reason, "form")
        XCTAssertEqual(
            try record("Notification", ["notification_type": "idle_prompt"])?.state,
            "idle"
        )
        XCTAssertEqual(try record("SessionEnd", ["reason": "logout"])?.state, "gone")
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
        state: String = "present", updatedAt: Double, kind: String? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "cwd": cwd, "state": state, "updatedAt": updatedAt,
        ]
        if let pane { value["tmuxPane"] = pane }
        if let socket { value["tmuxSocket"] = socket }
        if let kind { value["kind"] = kind }
        return value
    }
}
