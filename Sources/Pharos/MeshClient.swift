import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Thin client to the local mesh broker. Auto-spawns the daemon on first use
/// (like tmux), sends one request, and returns the response. `wait` blocks here
/// because the daemon holds the response open until a message arrives.
enum MeshClient {
    /// GUI-set remote broker endpoint ("ip:port"), resolved from the peer SSH
    /// host (see MeshRemote). When set, the app dials that broker instead of a
    /// local one and never auto-spawns a daemon. The `PHAROS_MESH_TCP` env var
    /// still takes precedence (agents / CLI). nil ⇒ use the local broker.
    nonisolated(unsafe) static var remoteEndpoint: String?

    /// The active remote endpoint: env > app-managed mesh-endpoint file > the
    /// GUI's in-memory resolution.
    private static var activeRemote: String? { MeshPaths.dialEndpoint ?? remoteEndpoint }

    /// Pick the transport: a remote broker over TCP when configured (this Mac
    /// dials another's broker), else the local UDS.
    static func connect() -> Int32? {
        if let ep = activeRemote { return meshTCPConnect(ep) }
        return connectUDS()
    }

    static func connectUDS() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        var addr = sockaddr_un()
        meshFillSockaddr(&addr, MeshPaths.socketPath)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { close(fd); return nil }
        return fd
    }

    /// When set (hub mode — see MeshHosting), a spawned local daemon binds TCP
    /// on this endpoint so peers can dial in.
    nonisolated(unsafe) static var hostTCPEndpoint: String?

    /// Stop the local broker and wait for it to actually exit, so a respawn
    /// rebinds cleanly (used when toggling hub mode on/off).
    static func stopLocalDaemon() {
        guard let fd = connectUDS() else { return }
        if let d = try? JSONEncoder().encode(MeshRequest(cmd: "shutdown")) {
            meshWriteAll(fd, d); _ = meshReadLine(fd)
        }
        close(fd)
        for _ in 0..<20 {                       // up to ~1s for it to vanish
            if let f = connectUDS() { close(f); usleep(50_000) } else { return }
        }
    }

    static func ensureDaemon() {
        if let fd = connectUDS() { close(fd); return }
        // Resolve symlinks so a `chat`-symlink invocation spawns the daemon as the
        // REAL binary (argv0 "Pharos", not "chat" — else its args get re-prefixed).
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: MeshPaths.supportDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = exe
        p.arguments = ["mesh", "daemon"]
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

    static func send(_ req: MeshRequest) -> MeshResponse {
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
