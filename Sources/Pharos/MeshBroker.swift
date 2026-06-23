import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Wire protocol (newline-delimited JSON over a local unix socket)

struct MeshRequest: Codable {
    var cmd: String                 // create | list | join | leave | say | wait | daemon
    var room: String?
    var nick: String?
    var text: String?
    var to: [String]?               // mention targets; empty/nil = whole room
    var timeoutMs: Int?
}

struct MeshMsg: Codable {
    var from: String
    var room: String
    var text: String
    var ts: Double
    var to: [String]
}

struct MeshRoomInfo: Codable { var name: String; var members: [String] }

struct MeshResponse: Codable {
    var ok: Bool
    var error: String?
    var rooms: [MeshRoomInfo]?
    var messages: [MeshMsg]?
    var note: String?

    static func okay(_ note: String? = nil) -> MeshResponse { MeshResponse(ok: true, note: note) }
    static func fail(_ e: String) -> MeshResponse { MeshResponse(ok: false, error: e) }
}

// MARK: - Paths (socket is always LOCAL; transcript lives in the data dir so the GUI/iCloud see it)

enum MeshPaths {
    /// Always-local Pharos app-support dir (never iCloud — a socket can't live in iCloud).
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Pharos", isDirectory: true)
    }
    static var socketPath: String { supportDir.appendingPathComponent("mesh.sock").path }
    static var daemonLog: URL { supportDir.appendingPathComponent("mesh-daemon.log") }

    /// Room transcripts live beside the registry (may be iCloud) so the GUI can show them.
    static var transcriptDir: URL {
        PharosCore.registryURL.deletingLastPathComponent().appendingPathComponent("mesh", isDirectory: true)
    }
    static func transcript(_ room: String) -> URL {
        transcriptDir.appendingPathComponent("\(room).jsonl")
    }
}

func meshLog(_ s: String) {
    guard ProcessInfo.processInfo.environment["MESH_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data(("[mesh] " + s + "\n").utf8))
}

// MARK: - Socket helpers

func meshFillSockaddr(_ addr: inout sockaddr_un, _ path: String) {
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        let n = min(bytes.count, raw.count - 1)            // leave room for the NUL
        raw.copyBytes(from: bytes.prefix(n))
    }
}

/// Read one newline-delimited line from a socket fd (byte-at-a-time; fine for our small frames).
func meshReadLine(_ fd: Int32) -> String? {
    var out = [UInt8]()
    var b: UInt8 = 0
    while true {
        let n = read(fd, &b, 1)
        if n <= 0 { return out.isEmpty ? nil : String(decoding: out, as: UTF8.self) }
        if b == 0x0A { return String(decoding: out, as: UTF8.self) }
        out.append(b)
    }
}

func meshWriteAll(_ fd: Int32, _ data: Data) {
    var payload = data
    payload.append(0x0A)
    payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard var p = raw.baseAddress else { return }
        var rem = raw.count
        while rem > 0 {
            let n = write(fd, p, rem)
            if n <= 0 { break }
            p = p.advanced(by: n); rem -= n
        }
    }
}

// MARK: - Broker daemon

/// In-memory chat broker. Holds rooms → members → per-member mailboxes, blocks
/// `wait` calls until a message addressed to that nick arrives (the "park" point),
/// and appends every message to a per-room transcript file for the GUI to read.
final class MeshBroker {
    private let lock = NSLock()
    private struct Room { var members = Set<String>(); var mailboxes: [String: [MeshMsg]] = [:] }
    private var rooms: [String: Room] = [:]

    private final class Waiter {
        let room: String; let nick: String
        let sem = DispatchSemaphore(value: 0)
        init(_ r: String, _ n: String) { room = r; nick = n }
    }
    private var waiters: [Waiter] = []

    static func runDaemon() -> Never {
        MeshBroker().serve()
        exit(0)   // unreachable
    }

    func serve() {
        signal(SIGPIPE, SIG_IGN)        // a hung-up client must not kill the daemon
        try? FileManager.default.createDirectory(at: MeshPaths.supportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: MeshPaths.transcriptDir, withIntermediateDirectories: true)

        let path = MeshPaths.socketPath
        if let fd = MeshClient.connect() { close(fd); exit(0) }   // a daemon already serves here — defer
        unlink(path)
        let sfd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sfd >= 0 else { fatalError("mesh: socket() failed (\(errno))") }
        var addr = sockaddr_un()
        meshFillSockaddr(&addr, path)
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRC == 0 else {
            if errno == EADDRINUSE { exit(0) }   // lost a startup race — let the winner serve
            fatalError("mesh: bind() failed (\(errno))")
        }
        listen(sfd, 64)
        meshLog("listening on \(path)")

        while true {
            let cfd = accept(sfd, nil, nil)
            if cfd < 0 { continue }
            Thread.detachNewThread { [weak self] in self?.handle(cfd) }
        }
    }

    private func handle(_ cfd: Int32) {
        defer { close(cfd) }
        meshLog("conn accepted fd=\(cfd)")
        guard let line = meshReadLine(cfd),
              let data = line.data(using: .utf8),
              let req = try? JSONDecoder().decode(MeshRequest.self, from: data) else {
            meshLog("read/decode failed")
            if let d = try? JSONEncoder().encode(MeshResponse.fail("bad request")) { meshWriteAll(cfd, d) }
            return
        }
        meshLog("req cmd=\(req.cmd) room=\(req.room ?? "-") nick=\(req.nick ?? "-")")
        let resp = process(req)               // for `wait`, this blocks until ready
        if let d = try? JSONEncoder().encode(resp) { meshWriteAll(cfd, d); meshLog("response written ok=\(resp.ok)") }
    }

    private func process(_ req: MeshRequest) -> MeshResponse {
        switch req.cmd {
        case "create":
            guard let r = req.room else { return .fail("room required") }
            lock.lock(); if rooms[r] == nil { rooms[r] = Room() }; lock.unlock()
            return .okay()

        case "list":
            lock.lock()
            let info = rooms.map { MeshRoomInfo(name: $0.key, members: Array($0.value.members).sorted()) }
                            .sorted { $0.name < $1.name }
            lock.unlock()
            return MeshResponse(ok: true, rooms: info)

        case "join":
            guard let r = req.room, let n = req.nick else { return .fail("room and nick required") }
            lock.lock()
            if rooms[r] == nil { rooms[r] = Room() }
            rooms[r]!.members.insert(n)
            if rooms[r]!.mailboxes[n] == nil { rooms[r]!.mailboxes[n] = [] }
            lock.unlock()
            return .okay()

        case "leave":
            guard let r = req.room, let n = req.nick else { return .fail("room and nick required") }
            lock.lock()
            rooms[r]?.members.remove(n)
            let wake = waiters.filter { $0.room == r }     // let peers re-evaluate (avoid deadlock)
            lock.unlock()
            for w in wake { w.sem.signal() }
            return .okay()

        case "say":
            guard let r = req.room, let n = req.nick, let t = req.text else { return .fail("room, nick and text required") }
            let msg = MeshMsg(from: n, room: r, text: t, ts: Date().timeIntervalSince1970, to: req.to ?? [])
            lock.lock()
            if rooms[r] == nil { rooms[r] = Room() }
            // mention-only when @targets given; otherwise broadcast to the rest of the room.
            let targets = (req.to?.isEmpty == false) ? req.to! : Array(rooms[r]!.members.subtracting([n]))
            for tg in targets { rooms[r]!.mailboxes[tg, default: []].append(msg) }
            let wake = waiters.filter { $0.room == r && targets.contains($0.nick) }
            lock.unlock()
            appendTranscript(msg)
            for w in wake { w.sem.signal() }
            return .okay()

        case "wait":
            guard let r = req.room, let n = req.nick else { return .fail("room and nick required") }
            let timeoutMs = req.timeoutMs ?? 60_000
            lock.lock()
            if rooms[r] == nil { rooms[r] = Room(); rooms[r]!.members.insert(n); rooms[r]!.mailboxes[n] = [] }
            if let box = rooms[r]!.mailboxes[n], !box.isEmpty {
                rooms[r]!.mailboxes[n] = []
                lock.unlock()
                return MeshResponse(ok: true, messages: box)        // already had mail — return now
            }
            let w = Waiter(r, n)
            waiters.append(w)
            lock.unlock()

            let res = w.sem.wait(timeout: .now() + .milliseconds(timeoutMs))   // ← the park

            lock.lock()
            waiters.removeAll { $0 === w }
            let msgs = rooms[r]?.mailboxes[n] ?? []
            rooms[r]?.mailboxes[n] = []
            lock.unlock()
            if res == .timedOut && msgs.isEmpty {
                return MeshResponse(ok: true, messages: [], note: "timeout")
            }
            return MeshResponse(ok: true, messages: msgs)

        default:
            return .fail("unknown cmd: \(req.cmd)")
        }
    }

    private func appendTranscript(_ m: MeshMsg) {
        let url = MeshPaths.transcript(m.room)
        guard var data = try? JSONEncoder().encode(m) else { return }
        data.append(0x0A)
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
