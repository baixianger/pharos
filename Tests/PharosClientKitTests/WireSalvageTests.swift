import XCTest
@testable import PharosClientKit

final class WireSalvageTests: XCTestCase {
    func testSessionAndProjectMetadataSurviveWireMapping() throws {
        let session = #"{"sessionId":"s","machineId":"m","agentType":"codex","workspacePath":"/p","title":"t","status":"unknown","updatedAt":"2026-11-11T08:00:00Z","avatarSeed":"a","inventoryStale":true,"connectionRoute":"remote"}"#.data(using: .utf8)!
        let mapped = try JSONDecoder().decode(APISessionSummary.self, from: session).asClient()
        XCTAssertEqual(mapped.status, .unknown)
        XCTAssertEqual(mapped.inventoryStale, true)
        XCTAssertEqual(mapped.connectionRoute, "remote")
        let project = #"{"projectId":"p","projectPath":"/p","name":"P","trackedDevices":[],"activeSessionsCount":1,"relatedSessionIds":["s"]}"#.data(using: .utf8)!
        let mappedProject = try JSONDecoder().decode(APIProjectSummary.self, from: project).asClient()
        XCTAssertEqual(mappedProject.id, "p")
        XCTAssertEqual(mappedProject.relatedSessionIds, ["s"])
    }

    func testProgressAndReplyDecodeFromRustWire() throws {
        let progress = #"{"goal":{"objective":"work","status":"active"},"todos":[{"text":"test","status":"inProgress"}]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CanonicalSessionProgress.self, from: progress)
        XCTAssertEqual(decoded.goal?.objective, "work")
        XCTAssertEqual(decoded.todos.first?.status, .inProgress)
        let message = #"{"id":"1","threadId":"t","senderId":"human","senderName":"You","text":"x","timestamp":"2026-11-11T08:00:00Z","receipt":"delivered","replyTo":{"messageId":"0","senderName":"A","preview":"hello"}}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(APIThreadMessage.self, from: message).asClient().replyTo?.messageId, "0")
    }
    func testRustProgressAndApprovalEventsMap() async throws {
        let client = HttpPharosClientService()
        let todo = #"{"eventType":"sessionTodosUpdated","sessionId":"s","todos":[{"text":"go","status":"pending"}]}"#.data(using: .utf8)!
        let event = await client.mapWireEvent(eventType: "sessionTodosUpdated", data: todo)
        guard case let .sessionTodosUpdated(id, todos) = event else { return XCTFail("missing todo event") }
        XCTAssertEqual(id, "s")
        XCTAssertEqual(todos.first?.text, "go")
        let withdrawn = #"{"eventType":"approvalWithdrawn","approvalId":"a"}"#.data(using: .utf8)!
        let approval = await client.mapWireEvent(eventType: "approvalWithdrawn", data: withdrawn)
        XCTAssertEqual(approval, .approvalWithdrawn(approvalId: "a"))
    }
}
