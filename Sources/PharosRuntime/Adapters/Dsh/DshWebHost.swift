import Foundation
import PharosClientKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public protocol DshInteractionHosting: Sendable {
    func interactions() async throws -> (String, AsyncStream<BackendWireEvent>)
    func resolveInteraction(clientID: String, eventID: String, outcomeData: Data) async throws
}

public protocol DshSessionHosting: Sendable {
    func history(sessionId: String) async throws -> [BackendWireEvent]
    func follow(sessionId: String) async throws -> AsyncStream<BackendWireEvent>
    func prompt(sessionId: String, text: String, mode: PromptMode) async throws
}

public protocol DshCommandHosting: Sendable {
    func executeCommand(sessionId: String, command: String) async throws -> BackendWireEvent
}

public protocol DshModelHosting: Sendable {
    func modelConfiguration(sessionId: String) async throws -> (catalog: BackendWireEvent, session: BackendWireEvent)
    func selectSessionModel(sessionId: String, provider: String, model: String) async throws -> BackendWireEvent
}

public struct DshStagedFile: Sendable, Equatable {
    public let receiptId: String
    public let attachmentId: String
    public let sessionId: String
    public let name: String
    public let byteCount: Int
}

public protocol DshAttachmentHosting: Sendable {
    func stageFile(sessionId: String, data: Data, name: String) async throws -> DshStagedFile
    func promptWithFiles(sessionId: String, text: String, files: [DshStagedFile], requestId: String, mode: PromptMode) async throws
}

public protocol DshPermissionHosting: Sendable {
    func permissionConfiguration(sessionId: String) async throws -> (catalog: BackendWireEvent, session: BackendWireEvent)
}

/// An app-owned loopback DSH Host. Its token stays in memory for the process lifetime.
public actor DshWebHost: DshInteractionHosting, DshSessionHosting, DshCommandHosting, DshModelHosting, DshPermissionHosting, DshAttachmentHosting {
    private let executable: URL
    private let environment: [String: String]?
    private let workspace: URL?
    private let remoteHost: String?
    private let sharedConnection: SharedSSHConnection?
    private let pluginModule: URL?
    private let additionalPatches: [URL]
    private var pluginOverlayDirectory: URL?
    private var process: Process?
    private var controlDirectory: URL?
    private var sharedForwardSpecification: String?
    private var mux: DshRemoteMux?
    private var replacingMux: Task<DshRemoteMux, Error>?
    private var output: Pipe?
    private var remoteInput: Pipe?
    private var endpoint: (port: Int, token: String)?
    private var stagedFiles: [String: [String: DshStagedFile]] = [:]
    private var attachmentSubmissions: Set<String> = []
    private var starting: Task<(Int, String), Error>?
    private let transport = DshWebHttpWsTransport()

    public init(executable: URL = URL(fileURLWithPath: "/opt/homebrew/bin/dsh"),
                environment: [String: String]? = nil, workspace: URL? = nil, remoteHost: String? = nil,
                sharedConnection: SharedSSHConnection? = nil, pluginModule: URL? = nil, additionalPatches: [URL] = []) {
        self.executable = executable
        self.environment = environment
        self.workspace = workspace
        self.remoteHost = remoteHost
        self.sharedConnection = sharedConnection
        self.pluginModule = pluginModule
        self.additionalPatches = additionalPatches
    }

    deinit {
        output?.fileHandleForReading.readabilityHandler = nil
        Self.stopHost(process, input: remoteInput, controlDirectory: controlDirectory)
        Self.cancelSharedForward(sharedConnection, specification: sharedForwardSpecification)
        transport.close()
        if let pluginOverlayDirectory { try? FileManager.default.removeItem(at: pluginOverlayDirectory) }
    }

    private func localPluginPatch() throws -> URL? {
        guard let pluginModule else { return nil }
        guard FileManager.default.fileExists(atPath: pluginModule.path) else {
            throw PharosClientError.operationFailed("Bundled DSH runtime plugin is unavailable")
        }
        if let pluginOverlayDirectory { return pluginOverlayDirectory.appendingPathComponent("plugin.yml") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pharos-dsh-overlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let quoted = String(decoding: try JSONEncoder().encode(pluginModule.path), as: UTF8.self)
            let patch = directory.appendingPathComponent("plugin.yml")
            try "- insert:\n    - id: pharos-runtime-bridge\n      name: \(quoted)\n".write(to: patch, atomically: true, encoding: .utf8)
            pluginOverlayDirectory = directory
            return patch
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func connect() async throws -> (Int, String) {
        if let endpoint, process?.isRunning == true {
            if let current = mux, await current.isClosed() {
                let replacement: Task<DshRemoteMux, Error>
                if let existing = replacingMux { replacement = existing }
                else {
                    let transport = transport
                    replacement = Task {
                        let cookie = try await transport.getCookie(port: endpoint.port, token: endpoint.token)
                        return try DshRemoteMux(port: endpoint.port, cookie: cookie)
                    }
                    replacingMux = replacement
                }
                do {
                    let newMux = try await replacement.value
                    if mux === current { mux = newMux }
                    replacingMux = nil
                }
                catch { replacingMux = nil; throw error }
            }
            return (endpoint.port, endpoint.token)
        }
        if starting != nil {
            while starting != nil { try await Task.sleep(for: .milliseconds(50)) }
            guard let endpoint, process?.isRunning == true else {
                throw PharosClientError.backendUnreachable(backend: "dsh", reason: "DSH Host startup failed")
            }
            return (endpoint.port, endpoint.token)
        }
        // Staged receipts belong to the old Host process and must not survive replacement.
        stagedFiles.removeAll()
        Self.stopHost(process, input: remoteInput, controlDirectory: controlDirectory)
        Self.cancelSharedForward(sharedConnection, specification: sharedForwardSpecification)
        sharedForwardSpecification = nil
        controlDirectory = nil
        endpoint = nil
        mux = nil
        replacingMux?.cancel()
        replacingMux = nil
        remoteInput = nil
        let process = Process()
        let pipe = Pipe()
        if let remoteHost {
            guard !remoteHost.isEmpty, !remoteHost.hasPrefix("-"), !remoteHost.contains("\n") else {
                throw PharosClientError.operationFailed("Invalid remote DSH host")
            }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let command = #"env PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin /opt/homebrew/bin/dsh web --no-open --port 0 --host 127.0.0.1 & child=$!; cat >/dev/null; kill "$child" 2>/dev/null; wait "$child" 2>/dev/null"#
            if let sharedConnection {
                guard sharedConnection.destination == remoteHost else {
                    throw PharosClientError.operationFailed("Remote DSH host does not match shared SSH connection")
                }
                process.arguments = try sharedConnection.commandArguments(command)
            } else {
                let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
                    .appendingPathComponent("pharos-dsh-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                controlDirectory = directory
                process.arguments = ["-M", "-S", directory.appendingPathComponent("control").path,
                    "-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", remoteHost, command]
            }
            let input = Pipe()
            process.standardInput = input
            remoteInput = input
        } else {
            process.executableURL = executable
            let patches = try [localPluginPatch()].compactMap { $0 } + additionalPatches
            process.arguments = ["web"] + patches.flatMap { ["--patch", $0.path] }
                + ["--no-open", "--port", "0", "--host", "127.0.0.1"]
        }
        process.environment = environment
        process.currentDirectoryURL = workspace
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch {
            if let controlDirectory { try? FileManager.default.removeItem(at: controlDirectory) }
            controlDirectory = nil
            throw PharosClientError.backendUnreachable(backend: "dsh", reason: "Could not start the DSH Host")
        }
        self.process = process
        output = pipe
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let task = Task.detached { try Self.readEndpoint(descriptor: descriptor) }
        starting = task
        do {
            let (remotePort, token) = try await task.value
            guard process.isRunning else {
                throw PharosClientError.backendUnreachable(backend: "dsh", reason: "DSH Host exited during startup")
            }
            let port: Int
            if let remoteHost {
                let forward = try Self.openTunnel(destination: remoteHost, remotePort: remotePort,
                    controlPath: controlDirectory?.appendingPathComponent("control").path, sharedConnection: sharedConnection)
                port = forward.port
                sharedForwardSpecification = sharedConnection == nil ? nil : forward.specification
            } else { port = remotePort }
            if remoteHost != nil {
                let cookie = try await transport.getCookie(port: port, token: token)
                mux = try DshRemoteMux(port: port, cookie: cookie)
            }
            endpoint = (port, token)
            starting = nil
            pipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
            return (port, token)
        } catch {
            starting = nil
            Self.stopHost(process, input: remoteInput, controlDirectory: controlDirectory)
            Self.cancelSharedForward(sharedConnection, specification: sharedForwardSpecification)
            sharedForwardSpecification = nil
            controlDirectory = nil
            remoteInput = nil
            mux = nil
            self.process = nil
            output = nil
            throw error
        }
    }

    private static func stopHost(_ process: Process?, input: Pipe?, controlDirectory: URL?) {
        guard let process else {
            if let controlDirectory { try? FileManager.default.removeItem(at: controlDirectory) }
            return
        }
        if process.isRunning {
            if let input {
                try? input.fileHandleForWriting.close()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { process.terminate() }
                }
            } else { process.terminate() }
        }
        if let controlDirectory {
            DispatchQueue.global().async {
                process.waitUntilExit()
                try? FileManager.default.removeItem(at: controlDirectory)
            }
        }
    }

    private static func cancelSharedForward(_ connection: SharedSSHConnection?, specification: String?) {
        guard let connection, let specification,
              let arguments = try? connection.forwardArguments(operation: "cancel", specification: specification) else { return }
        DispatchQueue.global().async {
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            command.arguments = arguments
            command.standardOutput = FileHandle.nullDevice
            command.standardError = FileHandle.nullDevice
            if (try? command.run()) != nil { command.waitUntilExit() }
        }
    }

    private static func openTunnel(destination: String, remotePort: Int, controlPath: String?,
                                   sharedConnection: SharedSSHConnection?) throws -> (port: Int, specification: String) {
        for _ in 0..<3 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { break }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound == 0 else { close(fd); continue }
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let got = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
            close(fd)
            guard got == 0 else { continue }
            let port = Int(UInt16(bigEndian: address.sin_port))
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let specification = "127.0.0.1:\(port):127.0.0.1:\(remotePort)"
            if let sharedConnection {
                command.arguments = try sharedConnection.forwardArguments(operation: "forward", specification: specification)
            } else if let controlPath {
                command.arguments = ["-S", controlPath, "-O", "forward", "-L", specification, "--", destination]
            } else { throw PharosClientError.operationFailed("Remote DSH control socket is unavailable") }
            command.standardOutput = FileHandle.nullDevice
            command.standardError = FileHandle.nullDevice
            do { try command.run() } catch { continue }
            command.waitUntilExit()
            if command.terminationStatus == 0 { return (port, specification) }
        }
        throw PharosClientError.backendUnreachable(backend: "dsh", reason: "Could not open remote DSH tunnel")
    }

    private static func readEndpoint(descriptor: Int32) throws -> (Int, String) {
        let deadline = Date().addingTimeInterval(20)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let regex = try NSRegularExpression(pattern: #"dsh web: http://127\.0\.0\.1:(\d+)/\?token=([^\s]+)"#)
        while Date() < deadline {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, 250)
            if ready < 0 && errno == EINTR { continue }
            if ready < 0 { break }
            if ready == 0 { continue }
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count < 64 * 1024 else { break }
            guard let newline = data.lastIndex(of: 0x0A) else { continue }
            let value = String(decoding: data[...newline], as: UTF8.self)
            guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let portRange = Range(match.range(at: 1), in: value),
                  let tokenRange = Range(match.range(at: 2), in: value),
                  let port = Int(value[portRange]) else { continue }
            return (port, String(value[tokenRange]))
        }
        throw PharosClientError.backendUnreachable(backend: "dsh", reason: "DSH Host did not announce a loopback endpoint")
    }

    public func history(sessionId: String) async throws -> [BackendWireEvent] {
        let (port, token) = try await connect()
        if remoteHost != nil {
            guard let mux else { throw PharosClientError.operationFailed("Remote DSH stream is unavailable") }
            // Keep the initial WebSocket frame small; older remote Hosts can
            // close the shared mux when a large snapshot exceeds its limit.
            // Older records are fetched through the paged HTTP endpoint below.
            let payload = try JSONSerialization.data(withJSONObject: ["args": ["request": ["address": ["kind": "session", "sessionId": sessionId], "maxMessages": 1]]])
            let stream = try await mux.open(endpoint: "session/follow", requestData: payload)
            var iterator = stream.makeAsyncIterator()
            guard let snapshot = await iterator.next(), snapshot["type"] as? String == "snapshot" else {
                throw PharosClientError.operationFailed("DSH did not return a session snapshot")
            }
            guard let through = snapshot["cursor"] as? Int, let records = snapshot["records"] as? [[String: Any]],
                  var hasMore = snapshot["hasMore"] as? Bool else {
                throw PharosClientError.operationFailed("DSH returned an invalid session snapshot")
            }
            var pages = [records]
            var before = (records.first?["event"] as? [String: Any])?["seq"] as? Int
            while hasMore && pages.count < 50 {
                guard let previous = before else { throw PharosClientError.operationFailed("DSH snapshot has no history cursor") }
                let page = try await transport.sessionPage(port: port, token: token, sessionId: sessionId,
                                                           beforeSeq: previous, throughSeq: through)
                guard let next = page["records"] as? [[String: Any]], let more = page["hasMore"] as? Bool else {
                    throw PharosClientError.operationFailed("DSH returned an invalid history page")
                }
                pages.append(next)
                hasMore = more
                before = (next.first?["event"] as? [String: Any])?["seq"] as? Int
                if hasMore && (before == nil || before == previous) {
                    throw PharosClientError.operationFailed("DSH returned an invalid history cursor")
                }
            }
            guard !hasMore else { throw PharosClientError.operationFailed("DSH history exceeds the current page limit") }
            return pages.reversed().flatMap { $0.map(BackendWireEvent.init) }
        }
        var pages: [[BackendWireEvent]] = []
        var before: Int?
        var hasMore = false
        repeat {
            let page = try await transport.sessionPage(port: port, token: token, sessionId: sessionId, beforeSeq: before)
            guard let records = page["records"] as? [[String: Any]], let pageHasMore = page["hasMore"] as? Bool else {
                throw PharosClientError.operationFailed("DSH returned an invalid history page")
            }
            pages.append(records.map(BackendWireEvent.init))
            hasMore = pageHasMore
            guard hasMore else { break }
            guard let cursor = page["cursor"] as? Int, cursor > 0, cursor != before else {
                throw PharosClientError.operationFailed("DSH returned an invalid history cursor")
            }
            before = cursor
        } while pages.count < 50
        if hasMore {
            throw PharosClientError.operationFailed("DSH history exceeds the current page limit")
        }
        return pages.reversed().flatMap { $0 }
    }

    public func prompt(sessionId: String, text: String, mode: PromptMode) async throws {
        let (port, token) = try await connect()
        let response = try await transport.sendPrompt(port: port, token: token, sessionId: sessionId, prompt: text, mode: mode)
        guard response["accepted"] as? Bool == true else {
            throw PharosClientError.operationFailed("DSH did not accept the prompt")
        }
    }

    /// Read the current Host model directory without changing the model selection.
    public func modelCatalog() async throws -> BackendWireEvent {
        let (port, token) = try await connect()
        return BackendWireEvent(try await transport.modelCatalog(port: port, token: token))
    }

    /// Read this exact Session's inventory projection.
    public func sessionSummary(sessionId: String) async throws -> BackendWireEvent {
        let (port, token) = try await connect()
        let list = try await transport.sessionList(port: port, token: token)
        guard let items = list["items"] as? [[String: Any]],
              let session = items.first(where: { $0["sessionId"] as? String == sessionId }) else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
        return BackendWireEvent(session)
    }

    public func modelConfiguration(sessionId: String) async throws -> (catalog: BackendWireEvent, session: BackendWireEvent) {
        let catalog = try await modelCatalog()
        return (catalog, try await sessionSummary(sessionId: sessionId))
    }

    public func permissionConfiguration(sessionId: String) async throws -> (catalog: BackendWireEvent, session: BackendWireEvent) {
        let (port, token) = try await connect()
        let catalog = BackendWireEvent(try await transport.permissionCatalog(port: port, token: token))
        return (catalog, try await sessionSummary(sessionId: sessionId))
    }

    public func selectSessionModel(sessionId: String, provider: String, model: String) async throws -> BackendWireEvent {
        let (port, token) = try await connect()
        return BackendWireEvent(try await transport.selectSessionModel(port: port, token: token, sessionId: sessionId, provider: provider, model: model))
    }

    /// Stage bytes on this Host for one exact Session. The receipt is Host-local and in memory.
    public func stageFile(sessionId: String, data: Data, name: String) async throws -> DshStagedFile {
        guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("\n"), !name.contains("\r") else {
            throw PharosClientError.operationFailed("Invalid attachment name")
        }
        let (port, token) = try await connect()
        let response = try await transport.stageFile(port: port, token: token, sessionId: sessionId, data: data, name: name)
        guard let receipt = response["receiptId"] as? String, !receipt.isEmpty,
              let file = response["file"] as? [String: Any], let attachmentId = file["attachmentId"] as? String, !attachmentId.isEmpty,
              let size = file["bytes"] as? Int, size == data.count else {
            throw PharosClientError.operationFailed("DSH returned an invalid staged file receipt")
        }
        let result = DshStagedFile(receiptId: receipt, attachmentId: attachmentId, sessionId: sessionId, name: name, byteCount: size)
        stagedFiles[sessionId, default: [:]][receipt] = result
        return result
    }

    /// Send staged files once to their owning Session, retaining receipts on rejection.
    public func promptWithFiles(sessionId: String, text: String, files: [DshStagedFile], requestId: String, mode: PromptMode = .queue) async throws {
        guard !requestId.isEmpty, !files.isEmpty,
              Set(files.map(\.receiptId)).count == files.count,
              files.allSatisfy({ $0.sessionId == sessionId && stagedFiles[sessionId]?[$0.receiptId] == $0 }) else {
            throw PharosClientError.operationFailed("Attachment receipts do not belong to this Session")
        }
        guard attachmentSubmissions.insert(sessionId).inserted else { throw PharosClientError.operationFailed("An attachment submission is already in progress") }
        defer { attachmentSubmissions.remove(sessionId) }
        let (port, token) = try await connect()
        guard files.allSatisfy({ stagedFiles[sessionId]?[$0.receiptId] == $0 }) else {
            throw PharosClientError.operationFailed("Attachment receipts expired after the DSH Host restarted")
        }
        var content: [[String: Any]] = files.map { ["type": "file", "receiptId": $0.receiptId] }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { content.append(["type": "text", "text": text]) }
        let response = try await transport.sendPromptContent(port: port, token: token, sessionId: sessionId, requestId: requestId, content: content, mode: mode)
        guard response["accepted"] as? Bool == true else { throw PharosClientError.operationFailed("DSH did not accept the attached message") }
        for file in files { stagedFiles[sessionId]?.removeValue(forKey: file.receiptId) }
    }

    /// Execute a DSH command through its native command plane rather than
    /// placing the slash text into a model prompt.
    @discardableResult
    public func executeCommand(sessionId: String, command: String) async throws -> BackendWireEvent {
        let (port, token) = try await connect()
        return BackendWireEvent(try await transport.executeCommandResponse(port: port, token: token, sessionId: sessionId, command: command))
    }

    public func createSession(workspacePath: String) async throws -> String {
        let (port, token) = try await connect()
        return try await transport.createSession(port: port, token: token, workspacePath: workspacePath)
    }

    public func follow(sessionId: String) async throws -> AsyncStream<BackendWireEvent> {
        let (port, token) = try await connect()
        if let mux {
            let payload = try JSONSerialization.data(withJSONObject: ["args": ["request": ["address": ["kind": "session", "sessionId": sessionId], "assistantStream": true, "maxMessages": 1]]])
            return try await mux.open(endpoint: "session/follow", requestData: payload)
        }
        return transport.observeMuxStream(port: port, token: token, sessionId: sessionId)
    }

    public func interactions() async throws -> (String, AsyncStream<BackendWireEvent>) {
        let (port, token) = try await connect()
        if let mux {
            let stream = try await mux.open(endpoint: "$events", requestData: Data(#"{"args":{}}"#.utf8))
            var iterator = stream.makeAsyncIterator()
            guard let first = await iterator.next(), first["type"] as? String == "ready", let clientID = first["clientId"] as? String else {
                throw PharosClientError.operationFailed("DSH interaction stream did not become ready")
            }
            return (clientID, stream)
        }
        return try await transport.observeInteractions(port: port, token: token)
    }

    public func resolveInteraction(clientID: String, eventID: String, outcomeData: Data) async throws {
        let (port, token) = try await connect()
        try await transport.interactionResult(port: port, token: token, clientID: clientID, eventID: eventID, outcomeData: outcomeData)
    }
}
