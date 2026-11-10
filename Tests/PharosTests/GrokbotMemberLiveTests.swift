import Foundation
import XCTest
import PharosClientKit
import PharosMeshCore
@testable import Pharos
@testable import PharosRuntime

/// Live grokbot Thread member E2E. Gate with `PHAROS_GROKBOT_MEMBER_TEST=1`.
/// Requires local `rust/target/debug/pharos-meshd`, human-proxy webhook env, and
/// a human reply via `pharos-mesh thread reply` within 45 minutes.
final class GrokbotMemberLiveTests: XCTestCase {
    func testRealGrokbotThreadMentionReplyWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PHAROS_GROKBOT_MEMBER_TEST"] == "1" else {
            throw XCTSkip("Set PHAROS_GROKBOT_MEMBER_TEST=1 for grokbot Thread member E2E")
        }
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let binary = repo.appendingPathComponent("rust/target/debug/pharos-meshd")
        let meshBin = repo.appendingPathComponent(".build/debug/pharos-mesh")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("Build rust/target/debug/pharos-meshd first")
        }
        guard FileManager.default.isExecutableFile(atPath: meshBin.path) else {
            throw XCTSkip("Build .build/debug/pharos-mesh first")
        }
        let webhookEnv = HumanProxyChannel.defaultWebhookEnvURL()
        guard HumanProxyChannel.loadWebhookConfig(from: webhookEnv) != nil else {
            throw XCTSkip("Missing ~/.config/pharos/human-proxy-webhook.env")
        }

        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let thread = "grokbot-\(token)"
        let marker = "PHAROS_GROKBOT_MEMBER_DONE_\(token)"
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "personal/pharos-msg-test/grokbot-member/\(token)", isDirectory: true
            )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let requests = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("personal/pharos-msg-test/human-requests", isDirectory: true)
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let socket = base.appendingPathComponent("agent-runtime.sock")
        let previousRuntime = getenv("PHAROS_AGENT_RUNTIME_SOCKET").map { String(cString: $0) }
        setenv("PHAROS_AGENT_RUNTIME_SOCKET", socket.path, 1)
        defer {
            if let previousRuntime {
                setenv("PHAROS_AGENT_RUNTIME_SOCKET", previousRuntime, 1)
            } else {
                unsetenv("PHAROS_AGENT_RUNTIME_SOCKET")
            }
        }

        let runtime = Process()
        runtime.executableURL = binary
        runtime.arguments = [
            "--socket", socket.path,
            "--data-dir", base.appendingPathComponent("runtime").path,
        ]
        runtime.standardOutput = FileHandle.nullDevice
        runtime.standardError = FileHandle.nullDevice
        try runtime.run()
        defer {
            if runtime.isRunning {
                runtime.terminate()
                runtime.waitUntilExit()
            }
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socket.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))

        // Isolated product mesh for the Thread (msg-test only).
        let meshDir = base.appendingPathComponent("mesh", isDirectory: true)
        try FileManager.default.createDirectory(at: meshDir, withIntermediateDirectories: true)
        let replica = try MeshLocalReplica.openHeadless(dataDirectory: meshDir)
        let group = try await replica.ensureActiveTrustGroup()
        try await replica.store.setMembershipEpoch(1, for: group)
        let registry = DistributedChatRegistry(replica: replica, group: group)
        let chat = DistributedAgentChat(replica: replica, group: group)
        _ = try await registry.createRoom(named: thread)
        _ = try await chat.join(
            room: thread, nick: GrokbotThreadBridge.displayNick,
            memberID: GrokbotThreadBridge.memberID
        )
        // Second real backend member (identity only) so the Thread is multi-agent.
        _ = try await chat.join(room: thread, nick: "agy-stub", memberID: "agy-stub-\(token)")
        let rooms = try await registry.rooms()
        let room = try XCTUnwrap(rooms.first { $0.name == thread })
        let human = try await registry.localHumanMember(in: room)

        let bridge = GrokbotThreadBridge(
            history: { name in try await chat.history(room: name, limit: 40) },
            hostLabel: "xiang-mac-mini"
        )
        try await bridge.ensureRegistered()
        try await bridge.poll()

        let original = try await registry.send(
            room: room, fromMemberID: human.id,
            text: "@\(GrokbotThreadBridge.displayNick) Reply exactly \(marker). Keep it short.",
            toMemberIDs: [GrokbotThreadBridge.memberID]
        )
        print("Grokbot member Thread=\(thread) message=\(original.stableID)")

        // Exact human-proxy instructions (webhook payload stays ID-only).
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        let requestName = "\(stamp)_grokbot-thread-mention.md"
        let readCmd =
            "\(meshBin.path) thread read --thread \(thread) --data-dir \(meshDir.path)"
        let replyFile = base.appendingPathComponent("reply.txt").path
        let replyCmd =
            "printf '%s\\n' '\(marker)' > \(replyFile) && " +
            "\(meshBin.path) thread reply --thread \(thread) --as grokbot " +
            "--message \(original.stableID) --text-file \(replyFile) --data-dir \(meshDir.path)"
        let md = """
        # Grokbot Thread mention

        - kind: thread-mention
        - thread: \(thread)
        - message: \(original.stableID)
        - from: \(human.id)
        - host: xiang-mac-mini
        - timeout: 45 minutes
        - rule: webhook payload is wake-only (IDs). Run only the commands below.

        ## Read

        ```sh
        \(readCmd)
        ```

        ## Reply as grokbot

        ```sh
        \(replyCmd)
        ```
        """
        try md.write(
            to: requests.appendingPathComponent(requestName),
            atomically: true, encoding: .utf8
        )
        print("Grokbot human-request written: \(requestName)")

        let target = MeshMemberInfo(
            id: GrokbotThreadBridge.memberID,
            nick: GrokbotThreadBridge.displayNick,
            session: GrokbotThreadBridge.memberID,
            kind: GrokbotThreadBridge.agentKind,
            rooms: [thread],
            lastSeen: Date().timeIntervalSince1970,
            runtimeOwnerIsLocal: true
        )
        let route = MeshRuntimeDeliveryBridge.submit(message: original, target: target)
        guard case .accepted = route else {
            return XCTFail("Runtime must accept grokbot delivery.submit-member, got \(route)")
        }

        // Bridge poll posts wake-only webhook and acks injected.
        try await bridge.poll()
        let pending = await bridge.pendingDelivery()
        XCTAssertNotNil(pending, "webhook success must leave delivery injected/pending")
        print(
            "Grokbot injected delivery=\(pending?.deliveryID ?? "?") " +
            "thread=\(pending?.thread ?? thread)"
        )

        let deadline = ContinuousClock.now.advanced(by: .seconds(45 * 60))
        var reply: MeshMsg?
        var sawInjected = pending != nil
        while ContinuousClock.now < deadline {
            try await bridge.poll()
            if await bridge.pendingDelivery() != nil { sawInjected = true }
            let snapshot = try AgyThreadRuntimeBridge.localRuntime("runtime.snapshot", [:]) as? [String: Any]
            let deliveries = snapshot?["deliveries"] as? [[String: Any]] ?? []
            if deliveries.contains(where: {
                ($0["state"] as? String) == "injected"
                    || ($0["state"] as? String) == "completed"
            }) {
                sawInjected = true
            }
            let history = try await chat.history(room: thread, limit: 20)
            reply = history.first {
                $0.authorMemberID == GrokbotThreadBridge.memberID
                    && $0.replyTo?.messageID == original.stableID
                    && $0.text.contains(marker)
            }
            if reply != nil { break }
            try await Task.sleep(for: .seconds(2))
        }
        XCTAssertTrue(sawInjected, "webhook success must surface as injected before replied")
        XCTAssertNotNil(reply, "grokbot replyOnce within 45m required for GROKBOT-MEMBER-DONE")
        // Advance injected → completed now that room replyOnce exists.
        try await bridge.poll()
        let cleared = await bridge.pendingDelivery()
        XCTAssertNil(cleared, "pending must clear after grokbot replyOnce")
        let snapshot = try XCTUnwrap(
            AgyThreadRuntimeBridge.localRuntime("runtime.snapshot", [:]) as? [String: Any]
        )
        let deliveries = try XCTUnwrap(snapshot["deliveries"] as? [[String: Any]])
        let completed = deliveries.filter { $0["state"] as? String == "completed" }.count
        let injectedOrBetter = deliveries.contains {
            ["injected", "completed"].contains($0["state"] as? String ?? "")
        }
        print(
            "Grokbot member DONE thread=\(thread) message=\(original.stableID) " +
            "reply=\(reply?.stableID ?? "?") completed=\(completed) marker=\(marker)"
        )
        XCTAssertTrue(injectedOrBetter, "honest path must have injected before completed")
        XCTAssertEqual(completed, 1)
    }
}
