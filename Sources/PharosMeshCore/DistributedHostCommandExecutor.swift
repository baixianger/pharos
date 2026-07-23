import Foundation
import PharosMeshProtocol
import PharosMeshReplica

/// Host-private routing metadata. Controllers address only the opaque resource
/// ID and generation; they cannot choose a tmux socket or session in payloads.
public struct DistributedHostResourceBinding: Codable, Equatable, Sendable {
    public static let version = 2

    public var schemaVersion: Int
    public var resourceID: String
    public var tmuxSession: String
    public var tmuxSocket: String?
    public var tmuxPane: String?
    public var tmuxSessionID: String?
    public var tmuxSessionCreatedAt: Int64?
    public var panePID: Int32?

    public init(
        resourceID: MeshResourceID, tmuxSession: String, tmuxSocket: String?,
        tmuxPane: String? = nil, tmuxSessionID: String? = nil,
        tmuxSessionCreatedAt: Int64? = nil, panePID: Int32? = nil
    ) throws {
        guard Self.validSession(tmuxSession), Self.validSocket(tmuxSocket),
              Self.validPane(tmuxPane), Self.validSessionID(tmuxSessionID),
              Self.validFingerprint(
                pane: tmuxPane, sessionID: tmuxSessionID,
                sessionCreatedAt: tmuxSessionCreatedAt, panePID: panePID
              ) else {
            throw DistributedHostExecutorError.invalidBinding
        }
        schemaVersion = Self.version
        self.resourceID = resourceID.rawValue
        self.tmuxSession = tmuxSession
        self.tmuxSocket = tmuxSocket
        self.tmuxPane = tmuxPane
        self.tmuxSessionID = tmuxSessionID
        self.tmuxSessionCreatedAt = tmuxSessionCreatedAt
        self.panePID = panePID
    }

    public func validate(for resourceID: MeshResourceID) throws {
        guard (1...Self.version).contains(schemaVersion),
              self.resourceID == resourceID.rawValue,
              Self.validSession(tmuxSession), Self.validSocket(tmuxSocket),
              Self.validPane(tmuxPane), Self.validSessionID(tmuxSessionID),
              Self.validFingerprint(
                pane: tmuxPane, sessionID: tmuxSessionID,
                sessionCreatedAt: tmuxSessionCreatedAt, panePID: panePID
              ) else {
            throw DistributedHostExecutorError.invalidBinding
        }
    }

    public var hasVerifiedRuntimeSeat: Bool {
        schemaVersion == Self.version
            && tmuxPane != nil && tmuxSessionID != nil
            && tmuxSessionCreatedAt != nil && panePID != nil
    }

    private static func validSession(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func validSocket(_ value: String?) -> Bool {
        guard let value else { return true }
        guard value.hasPrefix("/"), value.utf8.count <= 1_024 else { return false }
        return !URL(fileURLWithPath: value).pathComponents.contains("..")
    }

    private static func validPane(_ value: String?) -> Bool {
        guard let value else { return true }
        guard value.first == "%", value.utf8.count <= 32 else { return false }
        return value.dropFirst().allSatisfy(\.isNumber)
    }

    private static func validSessionID(_ value: String?) -> Bool {
        guard let value else { return true }
        guard value.first == "$", value.utf8.count <= 32 else { return false }
        return value.dropFirst().allSatisfy(\.isNumber)
    }

    private static func validFingerprint(
        pane: String?, sessionID: String?,
        sessionCreatedAt: Int64?, panePID: Int32?
    ) -> Bool {
        let fieldsAreAllPresent =
            pane != nil && sessionID != nil && sessionCreatedAt != nil && panePID != nil
        let fieldsAreAllAbsent =
            pane == nil && sessionID == nil && sessionCreatedAt == nil && panePID == nil
        guard fieldsAreAllPresent || fieldsAreAllAbsent else { return false }
        if let sessionCreatedAt, sessionCreatedAt <= 0 { return false }
        if let panePID, panePID <= 0 { return false }
        return true
    }
}

public struct DistributedHostResourceBindings: Sendable {
    public let directory: URL

    public init(dataDirectory: URL) {
        directory = dataDirectory.appendingPathComponent("host-resources-v1", isDirectory: true)
    }

    public func save(_ binding: DistributedHostResourceBinding, for resourceID: MeshResourceID) throws {
        try binding.validate(for: resourceID)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = fileURL(for: resourceID)
        try JSONEncoder().encode(binding).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destination.path
        )
    }

    public func load(_ resourceID: MeshResourceID) throws -> DistributedHostResourceBinding {
        let binding = try JSONDecoder().decode(
            DistributedHostResourceBinding.self,
            from: Data(contentsOf: fileURL(for: resourceID))
        )
        try binding.validate(for: resourceID)
        return binding
    }

    public func remove(_ resourceID: MeshResourceID) throws {
        let file = fileURL(for: resourceID)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func fileURL(for resourceID: MeshResourceID) -> URL {
        let name = resourceID.rawValue.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json", isDirectory: false)
    }
}

public struct DistributedHostPokePayload: Codable, Sendable {
    public var text: String

    public init(text: String) { self.text = text }

    public func validate() throws {
        guard !text.isEmpty, text.utf8.count <= 16_384,
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw DistributedHostExecutorError.invalidPayload
        }
    }
}

public struct DistributedHostCommandExecutor: Sendable {
    public let bindings: DistributedHostResourceBindings
    public let seatInspector: any DistributedTmuxSeatInspecting

    public init(
        bindings: DistributedHostResourceBindings,
        seatInspector: any DistributedTmuxSeatInspecting = DistributedTmuxSeatInspector()
    ) {
        self.bindings = bindings
        self.seatInspector = seatInspector
    }

    /// Wake a Host-local coding session with a fixed product-authored prompt.
    /// Remote callers must still use a signed host command; this entry point is
    /// for the owning Pharos process after it has verified local idle presence.
    public func pokeLocal(
        resourceID: MeshResourceID, text: String
    ) async -> MeshHostCommandExecutionOutcome {
        do {
            let payload = DistributedHostPokePayload(text: text)
            try payload.validate()
            let binding = try bindings.load(resourceID)
            try seatInspector.verify(binding)
            try await poke(binding: binding, text: text)
            return .executed(Data("poke-ok".utf8))
        } catch let error as DistributedHostExecutorError {
            return .failed(code: error.failureCode)
        } catch {
            return .failed(code: "host-execution-failed")
        }
    }

    /// Runs an interactive tmux client for a resource owned by this Host. SSH
    /// callers provide only the opaque resource ID; the private socket/session
    /// binding never leaves the Host.
    public func attachLocal(resourceID: MeshResourceID) throws -> Int32 {
        let binding = try bindings.load(resourceID)
        try seatInspector.verify(binding)
        let executable = try tmuxExecutable()
        if let socket = binding.tmuxSocket {
            let attributes = try FileManager.default.attributesOfItem(atPath: socket)
            guard attributes[.type] as? FileAttributeType == .typeSocket else {
                throw DistributedHostExecutorError.tmuxSocketUnavailable
            }
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = (binding.tmuxSocket.map { ["-S", $0] } ?? []) + [
            "attach-session", "-d", "-t", "=\(binding.tmuxSession)",
        ]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    public func execute(_ command: MeshHostCommand) async -> MeshHostCommandExecutionOutcome {
        do {
            let binding = try bindings.load(command.resourceID)
            try seatInspector.verify(binding)
            let executable = try tmuxExecutable()
            switch command.action {
            case .poke:
                let payload = try JSONDecoder().decode(
                    DistributedHostPokePayload.self, from: command.payload
                )
                try payload.validate()
                try await poke(executable: executable, binding: binding, text: payload.text)
                return .executed(Data("poke-ok".utf8))
            case .stop:
                guard command.payload.isEmpty else {
                    throw DistributedHostExecutorError.invalidPayload
                }
                try runTmux(
                    executable, binding: binding,
                    arguments: ["kill-session", "-t", "=\(binding.tmuxSession)"]
                )
                return .executed(Data("stop-ok".utf8))
            default:
                return .failed(code: "action-not-implemented")
            }
        } catch let error as DistributedHostExecutorError {
            return .failed(code: error.failureCode)
        } catch {
            return .failed(code: "host-execution-failed")
        }
    }

    /// Replays only the idempotent local side effect for a durably journaled
    /// stop receipt after a Host crash. A missing or replaced verified seat
    /// means the old resource is already gone and must never target the new one.
    public func recoverStop(
        resourceID: MeshResourceID
    ) async -> MeshHostCommandExecutionOutcome {
        do {
            let binding = try bindings.load(resourceID)
            guard binding.hasVerifiedRuntimeSeat else {
                throw DistributedHostExecutorError.unverifiedBinding
            }
            do {
                try seatInspector.verify(binding)
            } catch DistributedHostExecutorError.runtimeSeatMismatch {
                return .executed(Data("stop-already-gone".utf8))
            } catch DistributedHostExecutorError.tmuxSocketUnavailable {
                return .executed(Data("stop-already-gone".utf8))
            }
            do {
                try runTmux(
                    tmuxExecutable(), binding: binding,
                    arguments: ["kill-session", "-t", "=\(binding.tmuxSession)"]
                )
            } catch DistributedHostExecutorError.tmuxCommandFailed {
                return .executed(Data("stop-already-gone".utf8))
            }
            return .executed(Data("stop-ok".utf8))
        } catch let error as DistributedHostExecutorError {
            return .failed(code: error.failureCode)
        } catch {
            return .failed(code: "host-execution-failed")
        }
    }

    private func poke(
        binding: DistributedHostResourceBinding, text: String
    ) async throws {
        try await poke(executable: tmuxExecutable(), binding: binding, text: text)
    }

    private func poke(
        executable: URL, binding: DistributedHostResourceBinding, text: String
    ) async throws {
        try runTmux(
            executable, binding: binding,
            // `send-keys` resolves a pane target. The trailing colon turns the
            // exact session match into its active pane.
            arguments: ["send-keys", "-t", "=\(binding.tmuxSession):", "-l", "--", text]
        )
        // Full-screen coding-agent TUIs need one render turn before Enter;
        // sending both back-to-back can leave the text sitting in the composer.
        try await Task.sleep(for: .milliseconds(350))
        try runTmux(
            executable, binding: binding,
            arguments: ["send-keys", "-t", "=\(binding.tmuxSession):", "Enter"]
        )
    }

    private func tmuxExecutable() throws -> URL {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw DistributedHostExecutorError.tmuxUnavailable
        }
        return URL(fileURLWithPath: path)
    }

    private func runTmux(
        _ executable: URL, binding: DistributedHostResourceBinding,
        arguments: [String]
    ) throws {
        if let socket = binding.tmuxSocket {
            let attributes = try FileManager.default.attributesOfItem(atPath: socket)
            guard attributes[.type] as? FileAttributeType == .typeSocket else {
                throw DistributedHostExecutorError.tmuxSocketUnavailable
            }
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = (binding.tmuxSocket.map { ["-S", $0] } ?? []) + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DistributedHostExecutorError.tmuxCommandFailed
        }
    }
}

public enum DistributedHostExecutorError: Error {
    case invalidBinding
    case unverifiedBinding
    case runtimeSeatMismatch
    case invalidPayload
    case tmuxUnavailable
    case tmuxSocketUnavailable
    case tmuxCommandFailed

    public var failureCode: String {
        switch self {
        case .invalidBinding: "invalid-host-binding"
        case .unverifiedBinding: "unverified-host-binding"
        case .runtimeSeatMismatch: "runtime-seat-mismatch"
        case .invalidPayload: "invalid-command-payload"
        case .tmuxUnavailable: "tmux-unavailable"
        case .tmuxSocketUnavailable: "tmux-socket-unavailable"
        case .tmuxCommandFailed: "tmux-command-failed"
        }
    }
}
