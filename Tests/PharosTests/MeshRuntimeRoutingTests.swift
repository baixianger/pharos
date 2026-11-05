import XCTest
@testable import PharosMeshCore

final class MeshRuntimeRoutingTests: XCTestCase {
    private var hermeticDir: URL!

    override func setUp() {
        super.setUp()
        // MeshBroker() persists under PHAROS_MESH_DIR (default ~/Library/Application Support/Pharos).
        hermeticDir = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-hermetic-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: hermeticDir.appendingPathComponent("mesh-state/unread"),
                                                 withIntermediateDirectories: true)
        setenv("PHAROS_MESH_DIR", hermeticDir.path, 1)
        setenv("PHAROS_MESH_DATA_DIR", hermeticDir.appendingPathComponent("broker-data").path, 1)
    }

    override func tearDown() {
        unsetenv("PHAROS_MESH_DIR")
        unsetenv("PHAROS_MESH_DATA_DIR")
        try? FileManager.default.removeItem(at: hermeticDir)
        super.tearDown()
    }

    func testRuntimeAcceptedTargetDoesNotEnterLegacyMailbox() {
        var routed: [String] = []
        let broker = MeshBroker(runtimeDeliverySink: { message, target in
            routed.append("\(message.stableID):\(target.id)")
            return .accepted
        })
        join(broker, room: "runtime-route", nick: "human", session: "human-1")
        join(broker, room: "runtime-route", nick: "agent", session: "agent-1")
        let response = broker.process(MeshRequest(
            cmd: "say", room: "runtime-route", nick: "human", memberID: "human-1",
            text: "@agent hello", to: ["agent"]
        ))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(routed.count, 1)
        let inbox = broker.process(MeshRequest(cmd: "recv", memberID: "agent-1", limit: 10))
        XCTAssertEqual(inbox.messages ?? [], [])
    }

    func testRejectedRuntimeTargetFallsBackToLegacyMailbox() {
        let broker = MeshBroker(runtimeDeliverySink: { _, _ in .fallback })
        join(broker, room: "runtime-fallback", nick: "human", session: "human-2")
        join(broker, room: "runtime-fallback", nick: "agent", session: "agent-2")
        XCTAssertTrue(broker.process(MeshRequest(
            cmd: "say", room: "runtime-fallback", nick: "human", memberID: "human-2",
            text: "@agent fallback", to: ["agent"]
        )).ok)
        let inbox = broker.process(MeshRequest(cmd: "recv", memberID: "agent-2", limit: 10))
        XCTAssertEqual(inbox.messages?.map(\.text), ["@agent fallback"])
    }

    private func join(_ broker: MeshBroker, room: String, nick: String, session: String) {
        let response = broker.process(MeshRequest(
            cmd: "join", room: room, nick: nick, memberID: session,
            session: session, kind: nick == "human" ? "human" : "claude"
        ))
        XCTAssertTrue(response.ok)
    }
}
