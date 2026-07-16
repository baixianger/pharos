import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum MeshClientError: LocalizedError {
    case cannotConnect
    case invalidResponse(String)
    case file(String)

    public var errorDescription: String? {
        switch self {
        case .cannotConnect: "Cannot reach the Mesh broker."
        case .invalidResponse(let message): message
        case .file(let message): message
        }
    }
}

public struct MeshRegistrySnapshot: Sendable, Equatable {
    public let payload: String
    public let revision: String

    public init(payload: String, revision: String) {
        self.payload = payload
        self.revision = revision
    }
}

public enum MeshRegistryError: LocalizedError, Equatable {
    case conflict(currentRevision: String)

    public var errorDescription: String? {
        switch self {
        case .conflict:
            "The project registry changed on another client. Reload before saving again."
        }
    }
}

/// Thin client to the local mesh broker. Auto-spawns the daemon on first use
/// (like tmux), sends one request, and returns the response. `wait` blocks here
/// because the daemon holds the response open until a message arrives.
public enum MeshClient {
    /// GUI-set remote broker endpoint ("ip:port"), resolved from the peer SSH
    /// host (see MeshRemote). When set, the app dials that broker instead of a
    /// local one and never auto-spawns a daemon. The `PHAROS_MESH_TCP` env var
    /// still takes precedence (agents / CLI). nil ⇒ use the local broker.
    nonisolated(unsafe) public static var remoteEndpoint: String?

    /// The active remote endpoint: env > app-managed mesh-endpoint file > the
    /// GUI's in-memory resolution.
    private static var activeRemote: String? { MeshPaths.dialEndpoint ?? remoteEndpoint }

    /// Pick the transport: a remote broker over TCP when configured (this Mac
    /// dials another's broker), else the local UDS.
    public static func connect() -> Int32? {
        if let ep = activeRemote { return meshTCPConnect(ep) }
        return connectUDS()
    }

    public static func connectUDS() -> Int32? {
        let fd = socket(AF_UNIX, meshSocketStream(), 0)
        if fd < 0 { return nil }
        var addr = sockaddr_un()
        meshFillSockaddr(&addr, MeshPaths.socketPath)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                meshSystemConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { close(fd); return nil }
        return fd
    }

    /// When set (hub mode — see MeshHosting), a spawned local daemon binds TCP
    /// on this endpoint so peers can dial in.
    nonisolated(unsafe) public static var hostTCPEndpoint: String?

    /// Stop the local broker and wait for it to actually exit, so a respawn
    /// rebinds cleanly (used when toggling hub mode on/off).
    public static func stopLocalDaemon() {
        guard let fd = connectUDS() else { return }
        if let d = try? JSONEncoder().encode(MeshRequest(cmd: "shutdown")) {
            meshWriteAll(fd, d); _ = meshReadLine(fd)
        }
        close(fd)
        for _ in 0..<20 {                       // up to ~1s for it to vanish
            if let f = connectUDS() { close(f); usleep(50_000) } else { return }
        }
    }

    public static func ensureDaemon() {
        if let fd = connectUDS() { close(fd); return }
        // Resolve symlinks so a `chat`-symlink invocation spawns the daemon as the
        // REAL binary (argv0 "Pharos", not "chat" — else its args get re-prefixed).
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: MeshPaths.supportDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = exe
        p.arguments = exe.lastPathComponent == "pharos-mesh" ? ["daemon"] : ["mesh", "daemon"]
        if let ep = hostTCPEndpoint {           // hub mode: spawned broker binds TCP
            var env = ProcessInfo.processInfo.environment
            env["PHAROS_MESH_TCP"] = ep
            env["PHAROS_MESH_TCP_INSECURE"] = "1"
            p.environment = env
        }
        if !FileManager.default.fileExists(atPath: MeshPaths.daemonLog.path) {
            FileManager.default.createFile(atPath: MeshPaths.daemonLog.path, contents: nil)
        }
        if let log = try? FileHandle(forWritingTo: MeshPaths.daemonLog) {
            p.standardOutput = log; p.standardError = log
        }
        try? p.run()
        for _ in 0..<60 {                       // wait up to ~3s for the socket
            if let fd = connectUDS() { close(fd); return }
            usleep(50_000)
        }
    }

    /// Hook-safe send: NEVER spawns a daemon. Dial-out hosts use the normal TCP
    /// path (which never auto-spawns); locally we only talk to a broker that is
    /// already up. nil ⇒ nobody to tell — the caller must treat that as fine
    /// (hooks are fail-open; a dead broker also means nobody reads presence).
    @discardableResult
    public static func sendIfUp(_ req: MeshRequest) -> MeshResponse? {
        if activeRemote != nil { return send(req) }
        guard let fd = connectUDS() else { return nil }
        defer { close(fd) }
        return roundTrip(fd, req)
    }

    public static func send(_ req: MeshRequest) -> MeshResponse {
        // Remote broker (TCP): never auto-spawn a local daemon — just dial it.
        if let ep = activeRemote {
            guard let fd = connect() else { return .fail("cannot reach remote mesh broker at \(ep)") }
            defer { close(fd) }
            return roundTrip(fd, req)
        }
        if let e = MeshPaths.socketPathOverflow { return .fail(e) }
        ensureDaemon()
        guard let fd = connectUDS() else { return .fail("cannot reach mesh daemon") }
        defer { close(fd) }
        return roundTrip(fd, req)
    }

    /// Send directly to a specific TCP broker, bypassing the environment and
    /// app-managed endpoint file. Settings uses this to test the value being
    /// edited instead of accidentally reporting the previously saved broker.
    public static func send(_ req: MeshRequest, to endpoint: String,
                            timeoutSec: Double = 3) -> MeshResponse {
        guard let fd = meshTCPConnect(endpoint, timeoutSec: timeoutSec) else {
            return .fail("cannot reach mesh broker at \(endpoint)")
        }
        defer { close(fd) }
        return roundTrip(fd, req)
    }

    public static func uploadAttachment(fileAt url: URL, mimeType: String? = nil,
                                        id: String? = nil, name: String? = nil) throws -> MeshAttachment {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw MeshClientError.file("Cannot read attachment: \(error.localizedDescription)") }
        guard !data.isEmpty, data.count <= 25 * 1024 * 1024 else {
            throw MeshClientError.file("Attachments must be between 1 byte and 25 MiB.")
        }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let metadata = MeshAttachment(id: id ?? UUID().uuidString,
                                      name: name ?? url.lastPathComponent,
                                      mimeType: mimeType ?? inferredMIMEType(for: url),
                                      byteSize: data.count, sha256: sha)
        guard let fd = connectionForRequest() else { throw MeshClientError.cannotConnect }
        defer { close(fd) }
        let request = MeshRequest(cmd: "attachment-put", attachment: metadata)
        guard let header = try? JSONEncoder().encode(request) else {
            throw MeshClientError.invalidResponse("Cannot encode attachment request.")
        }
        meshWriteAll(fd, header)
        meshWriteRaw(fd, data)
        let response = try readResponse(fd)
        guard response.ok, let stored = response.attachment else {
            throw MeshClientError.invalidResponse(response.error ?? "Attachment upload failed.")
        }
        return stored
    }

    /// Fetch the Broker-owned project registry and its content revision. The
    /// revision is required for the next conditional write, preventing a stale
    /// Mac or CLI process from silently overwriting another client's changes.
    public static func fetchRegistry() throws -> MeshRegistrySnapshot {
        let response = send(MeshRequest(cmd: "registry-get"))
        guard response.ok, let payload = response.payload, let revision = response.revision else {
            throw MeshClientError.invalidResponse(response.error ?? "Registry fetch failed.")
        }
        return MeshRegistrySnapshot(payload: payload, revision: revision)
    }

    /// Replace the Broker registry only if `expectedRevision` still matches.
    /// A conflict is returned to the caller and is never converted into a
    /// last-writer-wins overwrite.
    public static func replaceRegistry(payload: String, expectedRevision: String) throws -> String {
        let response = send(MeshRequest(cmd: "registry-put", payload: payload,
                                        expectedRevision: expectedRevision))
        guard response.ok, let revision = response.revision else {
            if let current = response.revision {
                throw MeshRegistryError.conflict(currentRevision: current)
            }
            throw MeshClientError.invalidResponse(response.error ?? "Registry write failed.")
        }
        return revision
    }

    @discardableResult
    public static func downloadAttachment(id: String, to destination: URL) throws -> URL {
        guard let fd = connectionForRequest() else { throw MeshClientError.cannotConnect }
        defer { close(fd) }
        let request = MeshRequest(cmd: "attachment-get", attachmentID: id)
        guard let header = try? JSONEncoder().encode(request) else {
            throw MeshClientError.invalidResponse("Cannot encode attachment request.")
        }
        meshWriteAll(fd, header)
        let response = try readResponse(fd)
        guard response.ok, let attachment = response.attachment else {
            throw MeshClientError.invalidResponse(response.error ?? "Attachment download failed.")
        }
        guard let bytes = meshReadExactly(fd, count: attachment.byteSize) else {
            throw MeshClientError.invalidResponse("Attachment download ended early.")
        }
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard sha == attachment.sha256.lowercased() else {
            throw MeshClientError.invalidResponse("Attachment checksum mismatch.")
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try bytes.write(to: destination, options: .atomic)
            return destination
        } catch {
            throw MeshClientError.file("Cannot save attachment: \(error.localizedDescription)")
        }
    }

    private static func connectionForRequest() -> Int32? {
        if activeRemote != nil { return connect() }
        ensureDaemon()
        return connectUDS()
    }

    private static func readResponse(_ fd: Int32) throws -> MeshResponse {
        guard let line = meshReadLine(fd), let data = line.data(using: .utf8),
              let response = try? JSONDecoder().decode(MeshResponse.self, from: data) else {
            throw MeshClientError.invalidResponse("The Mesh broker returned an invalid response.")
        }
        return response
    }

    private static func inferredMIMEType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "heic", "heif": "image/heic"
        case "webp": "image/webp"
        case "pdf": "application/pdf"
        case "txt", "md": "text/plain"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }

    /// One request → one response over an already-connected fd (UDS or TCP).
    private static func roundTrip(_ fd: Int32, _ req: MeshRequest) -> MeshResponse {
        guard let data = try? JSONEncoder().encode(req) else { return .fail("encode failed") }
        meshWriteAll(fd, data)
        guard let line = meshReadLine(fd),
              let rdata = line.data(using: .utf8),
              let resp = try? JSONDecoder().decode(MeshResponse.self, from: rdata) else {
            return .fail("no/invalid response")
        }
        return resp
    }
}
