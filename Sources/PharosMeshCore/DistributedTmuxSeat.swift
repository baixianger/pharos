import Foundation

public struct DistributedTmuxSeat: Equatable, Sendable {
    public var sessionName: String
    public var socket: String?
    public var paneID: String
    public var sessionID: String
    public var sessionCreatedAt: Int64
    public var panePID: Int32

    public init(
        sessionName: String, socket: String?, paneID: String,
        sessionID: String, sessionCreatedAt: Int64, panePID: Int32
    ) {
        self.sessionName = sessionName
        self.socket = socket
        self.paneID = paneID
        self.sessionID = sessionID
        self.sessionCreatedAt = sessionCreatedAt
        self.panePID = panePID
    }
}

public protocol DistributedTmuxSeatInspecting: Sendable {
    func resolve(socket: String?, pane: String) throws -> DistributedTmuxSeat
}

public extension DistributedTmuxSeatInspecting {
    func verify(_ binding: DistributedHostResourceBinding) throws {
        guard binding.hasVerifiedRuntimeSeat,
              let pane = binding.tmuxPane,
              let sessionID = binding.tmuxSessionID,
              let sessionCreatedAt = binding.tmuxSessionCreatedAt,
              let panePID = binding.panePID else {
            throw DistributedHostExecutorError.unverifiedBinding
        }
        let seat = try resolve(socket: binding.tmuxSocket, pane: pane)
        guard seat.sessionName == binding.tmuxSession,
              seat.socket == binding.tmuxSocket,
              seat.paneID == pane,
              seat.sessionID == sessionID,
              seat.sessionCreatedAt == sessionCreatedAt,
              seat.panePID == panePID else {
            throw DistributedHostExecutorError.runtimeSeatMismatch
        }
    }
}

public struct DistributedTmuxSeatInspector: DistributedTmuxSeatInspecting {
    public init() {}

    public func resolve(socket: String?, pane: String) throws -> DistributedTmuxSeat {
        guard pane.first == "%",
              pane.dropFirst().allSatisfy(\.isNumber) else {
            throw DistributedHostExecutorError.invalidBinding
        }
        let executable = try tmuxExecutable()
        let process = Process()
        process.executableURL = executable
        process.arguments = (socket.map { ["-S", $0] } ?? []) + [
            "display-message", "-p", "-t", pane,
            "#{session_name}\t#{session_id}\t#{session_created}\t#{pane_id}\t#{pane_pid}",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DistributedHostExecutorError.runtimeSeatMismatch
        }
        let value = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = value.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 5,
              let createdAt = Int64(fields[2]),
              let panePID = Int32(fields[4]) else {
            throw DistributedHostExecutorError.runtimeSeatMismatch
        }
        return DistributedTmuxSeat(
            sessionName: String(fields[0]), socket: socket,
            paneID: String(fields[3]), sessionID: String(fields[1]),
            sessionCreatedAt: createdAt, panePID: panePID
        )
    }

    private func tmuxExecutable() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux",
        ]
        guard let path = candidates.first(
            where: FileManager.default.isExecutableFile(atPath:)
        ) else {
            throw DistributedHostExecutorError.tmuxUnavailable
        }
        return URL(fileURLWithPath: path)
    }
}
