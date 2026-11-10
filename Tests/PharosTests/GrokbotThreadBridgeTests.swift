import Foundation
import XCTest
import PharosClientKit
import PharosMeshCore
@testable import PharosRuntime

final class GrokbotThreadBridgeTests: XCTestCase {
    func testWebhookSuccessIsInjectedNotReplied() async throws {
        let runtime = GrokbotFixtureRuntime()
        let history = GrokbotFixtureHistory()
        let counter = NotifyCounter()
        let bridge = GrokbotThreadBridge(
            runtime: { method, params in try runtime.handle(method, params) },
            history: { room in await history.messages(in: room) },
            notify: { _, _, _, _ in
                await counter.increment()
                return .posted(statusCode: 200)
            },
            hostLabel: "mini"
        )
        try await bridge.ensureRegistered()
        try await bridge.poll() // empty
        let empty = await bridge.pendingDelivery()
        XCTAssertNil(empty)

        let messageID = "msg-1"
        try runtime.enqueue(
            memberID: GrokbotThreadBridge.memberID,
            room: "thread-a",
            messageID: messageID,
            sender: "human",
            text: "@Pharos hello"
        )
        try await bridge.poll()
        let pendingOpt = await bridge.pendingDelivery()
        let pending = try XCTUnwrap(pendingOpt)
        XCTAssertEqual(pending.messageID, messageID)
        XCTAssertEqual(pending.thread, "thread-a")
        let notifyCount = await counter.value
        XCTAssertEqual(notifyCount, 1)
        XCTAssertEqual(runtime.acks[pending.deliveryID], "injected")

        // Still injected until replyOnce appears in room history.
        try await bridge.poll()
        let still = await bridge.pendingDelivery()
        XCTAssertEqual(still?.deliveryID, pending.deliveryID)
        XCTAssertEqual(runtime.acks[pending.deliveryID], "injected")

        await history.append(
            MeshMsg(
                id: "reply-1", from: GrokbotThreadBridge.displayNick,
                room: "thread-a", text: "ack", ts: Date().timeIntervalSince1970,
                to: ["human"], authorMemberID: GrokbotThreadBridge.memberID,
                targetMemberIDs: [],
                replyTo: MeshReply(
                    messageID: messageID, from: "human", preview: "hello", ts: 1
                )
            )
        )
        try await bridge.poll()
        let cleared = await bridge.pendingDelivery()
        XCTAssertNil(cleared)
        XCTAssertEqual(runtime.acks[pending.deliveryID], "completed")
    }

    func testMissingWebhookFailsDelivery() async throws {
        let runtime = GrokbotFixtureRuntime()
        let history = GrokbotFixtureHistory()
        let bridge = GrokbotThreadBridge(
            runtime: { method, params in try runtime.handle(method, params) },
            history: { room in await history.messages(in: room) },
            notify: { _, _, _, _ in .skippedMissingConfig },
            hostLabel: "mini"
        )
        try await bridge.ensureRegistered()
        try runtime.enqueue(
            memberID: GrokbotThreadBridge.memberID,
            room: "thread-b",
            messageID: "msg-2",
            sender: "human",
            text: "@grokbot ping"
        )
        try await bridge.poll()
        let pending = await bridge.pendingDelivery()
        XCTAssertNil(pending)
        let failed = runtime.acks.first { $0.value == "failed" }
        XCTAssertNotNil(failed)
    }

    func testThreadMentionPayloadIsIDOnly() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pharos-missing-\(UUID().uuidString).env")
        let result = await HumanProxyChannel.notifyThreadMention(
            thread: "t1", messageID: "m1", from: "human", host: "mini",
            envFile: missing
        )
        XCTAssertEqual(result, .skippedMissingConfig)
    }
}

private actor NotifyCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor GrokbotFixtureHistory {
    private var rows: [String: [MeshMsg]] = [:]
    func messages(in room: String) -> [MeshMsg] { rows[room] ?? [] }
    func append(_ message: MeshMsg) {
        rows[message.room, default: []].append(message)
    }
}

private final class GrokbotFixtureRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var conversationID = "conv-grokbot"
    private var queue: [[String: Any]] = []
    private(set) var acks: [String: String] = [:]

    func enqueue(
        memberID: String, room: String, messageID: String, sender: String, text: String
    ) throws {
        let envelope: [String: Any] = [
            "body": text,
            "room": room,
            "messageID": messageID,
            "sender": sender,
            "meshMessage": [
                "id": messageID,
                "from": sender,
                "room": room,
                "text": text,
                "targetMemberIDs": [memberID],
            ],
        ]
        let payload = String(
            decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self
        )
        lock.lock()
        queue.append([
            "id": UUID().uuidString,
            "payload": payload,
            "state": "queued",
        ])
        lock.unlock()
    }

    func handle(_ method: String, _ params: [String: Any]) throws -> Any {
        lock.lock()
        defer { lock.unlock() }
        switch method {
        case "driver.register":
            return ["ok": true]
        case "conversation.register":
            return ["id": conversationID]
        case "conversation.state":
            return ["ok": true]
        case "delivery.poll":
            return queue
        case "delivery.ack":
            let id = params["deliveryID"] as? String ?? ""
            let state = params["state"] as? String ?? ""
            acks[id] = state
            if state == "injected" || state == "failed" || state == "completed" {
                queue.removeAll { ($0["id"] as? String) == id }
            }
            return ["ok": true]
        default:
            throw PharosClientError.operationFailed("unexpected \(method)")
        }
    }
}
