import Foundation
import XCTest
@testable import PharosMeshCore

final class DistributedTmuxSeatTests: XCTestCase {
    func testRealTmuxOutputResolvesAnExactSeat() throws {
        let executable = URL(fileURLWithPath: "/opt/homebrew/bin/tmux")
        guard FileManager.default.isExecutableFile(atPath: executable.path)
        else {
            throw XCTSkip("tmux is unavailable")
        }
        let suffix = UUID().uuidString.prefix(8)
        let socket = "/tmp/pharos-seat-\(suffix).sock"
        defer {
            _ = try? run(executable, ["-S", socket, "kill-server"])
        }

        _ = try run(
            executable,
            ["-S", socket, "new-session", "-d", "-s", "seat-test"]
        )
        let pane = try run(
            executable,
            ["-S", socket, "display-message", "-p", "-t", "=seat-test:",
             "#{pane_id}"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let seat = try DistributedTmuxSeatInspector().resolve(
            socket: socket, pane: pane
        )

        XCTAssertEqual(seat.sessionName, "seat-test")
        XCTAssertEqual(seat.socket, socket)
        XCTAssertEqual(seat.paneID, pane)
        XCTAssertTrue(seat.sessionID.hasPrefix("$"))
        XCTAssertGreaterThan(seat.sessionCreatedAt, 0)
        XCTAssertGreaterThan(seat.panePID, 0)
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "DistributedTmuxSeatTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: text]
            )
        }
        return text
    }
}
