import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Thin client to the local mesh broker. Auto-spawns the daemon on first use
/// (like tmux), sends one request, and returns the response. `wait` blocks here
/// because the daemon holds the response open until a message arrives.
enum MeshClient {
    /// Pick the transport: a remote broker over TCP when `PHAROS_MESH_TCP` is
    /// set (this Mac dials another's broker), else the local UDS.
    static func connect() -> Int32? {
        if let ep = MeshPaths.tcpEndpoint { return meshTCPConnect(ep) }
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

    static func ensureDaemon() {
        if let fd = connect() { close(fd); return }
        // Resolve symlinks so a `chat`-symlink invocation spawns the daemon as the
        // REAL binary (argv0 "Pharos", not "chat" — else its args get re-prefixed).
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: MeshPaths.supportDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = exe
        p.arguments = ["mesh", "daemon"]
        if !FileManager.default.fileExists(atPath: MeshPaths.daemonLog.path) {
            FileManager.default.createFile(atPath: MeshPaths.daemonLog.path, contents: nil)
        }
        if let log = try? FileHandle(forWritingTo: MeshPaths.daemonLog) {
            p.standardOutput = log; p.standardError = log
        }
        try? p.run()
        for _ in 0..<60 {                       // wait up to ~3s for the socket
            if let fd = connect() { close(fd); return }
            usleep(50_000)
        }
    }

    static func send(_ req: MeshRequest) -> MeshResponse {
        // Remote broker (TCP): never auto-spawn a local daemon — just dial it.
        if let ep = MeshPaths.tcpEndpoint {
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
