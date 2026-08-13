import XCTest

@MainActor
final class ChatRoomFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PHAROS_DEMO"] = "1"
        app.launchArguments += ["--ui-tab", "chat"]
        app.launch()
    }

    func testChatOpensAtLatestMessageWithComposerVisible() {
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["chat-message-demo-14"].exists)
    }

    func testComposerKeyboardAndMessageTapDismissal() {
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Mention atlas"].exists)
        let composer = app.textFields["chat-composer"]
        composer.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3))

        let message = app.otherElements["chat-message-demo-14"]
        XCTAssertTrue(message.exists)
        message.tap()
        XCTAssertFalse(app.keyboards.element.waitForExistence(timeout: 1))
    }

    func testPhotoAttachmentPickerPresentationDoesNotExitChat() {
        XCTAssertTrue(app.buttons["Add attachment"].waitForExistence(timeout: 5))
        app.buttons["Add attachment"].tap()

        let photos = app.buttons["Photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 2))
        photos.tap()

        // The system picker may vary by simulator/runtime, but presenting it
        // must not terminate the host app or lose the room composer.
        XCTAssertTrue(app.waitForExistence(timeout: 2))
    }
}
