import XCTest
@testable import PharosMeshCore

final class DistributedHookSessionIdentityTests: XCTestCase {
    func testPreallocatedMeshSessionOverridesRuntimeHookSession() {
        XCTAssertEqual(
            DistributedHookCLI.sessionID(
                payload: ["session_id": "runtime-session"],
                environment: ["PHAROS_MESH_SESSION": "stable-member"]
            ),
            "stable-member"
        )
    }

    func testRuntimeHookSessionRemainsFallbackForOrdinaryLaunches() {
        XCTAssertEqual(
            DistributedHookCLI.sessionID(
                payload: ["session_id": "runtime-session"], environment: [:]
            ),
            "runtime-session"
        )
    }
}
