import XCTest
@testable import Pharos

final class ContentRouteStateTests: XCTestCase {
    func testLateRoomWriteCannotReopenDashboardRoute() {
        XCTAssertNil(ContentRouteState.applyingRoomWrite(
            current: nil, next: "beiou-dev"
        ))
    }

    func testActiveChatRouteCanSwitchRooms() {
        XCTAssertEqual(
            ContentRouteState.applyingRoomWrite(
                current: "pharos-dev", next: "beiou-dev"
            ),
            "beiou-dev"
        )
    }
}
