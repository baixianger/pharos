import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Wire protocol (newline-delimited JSON over a local unix socket)

struct MeshRequest: Codable {
    var cmd: String                 // create | list | join | leave | say | wait | recv | daemon
    var room: String?
    var nick: String?
    var text: String?
    var to: [String]?               // mention targets; empty/nil = whole room
    var timeoutMs: Int?
    var limit: Int?                 // history / join catch-up size
    var project: String?            // join only: the joiner's cwd, recorded in presence
    var session: String?            // join only: the joiner's CC session id (exact addressing)
}

struct MeshMsg: Codable {
    var from: String
    var room: String
    var text: String
    var ts: Double
    var to: [String]
}

struct MeshRoomInfo: Codable { var name: String; var members: [String] }

// MARK: - Mirrored local state (the zero-daemon surface the hooks read)

/// Per-nick unread signal file: a mirror of the nick's in-RAM mailboxes across
/// all rooms, rewritten by the broker on every deliver and every drain. The
/// file EXISTS iff something is unread — hooks check it with a pure local read,
/// so a dead broker can never error or trap an agent.
struct MeshUnread: Codable {
    var v: Int
    var nick: String
    var count: Int
    var rooms: [String: Int]        // room → unread count
    var messages: [MeshMsg]         // oldest→newest (capped)
    var updatedTs: Double
}

/// nick → where it joined from + what rooms it's in. Lets a hook resolve
/// cwd → nick with a pure file read (join records the CLI's cwd as `project`).
struct MeshPresenceEntry: Codable {
    var project: String?
    var session: String?            // CC session id (from --session at join); nil for older/cwd-only joins
    var rooms: [String]
    var lastSeen: Double
    var online: Bool
}

struct MeshPresence: Codable {
    var v: Int
    var nicks: [String: MeshPresenceEntry]
}

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
    /// Always-local Pharos app-support dir (never iCloud — a socket can't live in
    /// iCloud). `PHAROS_MESH_DIR` overrides it so tests can run a hermetic broker
    /// without touching the live one (mirrors `PHAROS_REGISTRY`).
    static var supportDir: URL {
        if let o = ProcessInfo.processInfo.environment["PHAROS_MESH_DIR"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Pharos", isDirectory: true)
    }
    static var socketPath: String { supportDir.appendingPathComponent("mesh.sock").path }
    static var daemonLog: URL { supportDir.appendingPathComponent("mesh-daemon.log") }

    /// Cross-host transport (see MeshTCP.swift). `PHAROS_MESH_TCP=host:port`
    /// makes the broker also listen on TCP and clients dial it instead of the
    /// local UDS. Unauthenticated (Tailscale is the trust boundary), so the
    /// broker refuses to bind unless `PHAROS_MESH_TCP_INSECURE=1` is also set.
    static var tcpEndpoint: String? {
        guard let v = ProcessInfo.processInfo.environment["PHAROS_MESH_TCP"], !v.isEmpty else { return nil }
        return v
    }
    static var tcpInsecureOptIn: Bool {
        ProcessInfo.processInfo.environment["PHAROS_MESH_TCP_INSECURE"] == "1"
    }

    /// Darwin's `sun_path` holds 104 bytes including the NUL — a longer socket
    /// path silently truncates in `meshFillSockaddr` and binds/connects somewhere
    /// unintended. Non-nil = the clear diagnostic to surface instead.
    static var socketPathOverflow: String? {
        let n = socketPath.utf8.count
        guard n > 103 else { return nil }
        return "mesh socket path too long: \(socketPath) (\(n) chars > 103) — set a shorter PHAROS_MESH_DIR"
    }

    /// Local-only mesh runtime state (never iCloud): per-nick unread signal
    /// files + presence. Mirrors the broker's RAM, so a fresh daemon wipes it —
    /// the hooks must never read a signal the current broker didn't write.
    static var stateDir: URL { supportDir.appendingPathComponent("mesh-state", isDirectory: true) }
    static var unreadDir: URL { stateDir.appendingPathComponent("unread", isDirectory: true) }
    static var presenceFile: URL { stateDir.appendingPathComponent("presence.json") }
    static func unreadFile(_ nick: String) -> URL {
        let safe = String(nick.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
        return unreadDir.appendingPathComponent("\(safe).json")
    }

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
    private var presence: [String: MeshPresenceEntry] = [:]

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
        try? FileManager.default.createDirectory(at: MeshPaths.unreadDir, withIntermediateDirectories: true)
        // Fresh broker = fresh RAM: reset the mirrored state so hooks never see
        // a signal this broker didn't write. Transcripts (durable) are untouched.
        if let stale = try? FileManager.default.contentsOfDirectory(at: MeshPaths.unreadDir, includingPropertiesForKeys: nil) {
            for f in stale { try? FileManager.default.removeItem(at: f) }
        }
        writePresenceLocked()

        let path = MeshPaths.socketPath
        if let e = MeshPaths.socketPathOverflow {
            FileHandle.standardError.write(Data((e + "\n").utf8))
            exit(1)
        }
        if let fd = MeshClient.connectUDS() { close(fd); exit(0) }   // a daemon already serves here — defer
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
        startTCPListenerIfConfigured()

        while true {
            let cfd = accept(sfd, nil, nil)
            if cfd < 0 { continue }
            Thread.detachNewThread { [weak self] in self?.handle(cfd) }
        }
    }

    /// Bring up the cross-host TCP listener when `PHAROS_MESH_TCP` is set. Runs
    /// its accept loop on a detached thread; each connection is driven by the
    /// same `handle` as UDS. Refuses to bind without the insecure opt-in, and
    /// serving UDS continues regardless of any TCP failure.
    private func startTCPListenerIfConfigured() {
        guard let ep = MeshPaths.tcpEndpoint else { return }
        guard MeshPaths.tcpInsecureOptIn else {
            let msg = "mesh: refusing to bind TCP \(ep) without auth — set PHAROS_MESH_TCP_INSECURE=1 to allow "
                    + "(trusted Tailscale network only). Serving UDS only.\n"
            FileHandle.standardError.write(Data(msg.utf8))
            return
        }
        guard let tfd = meshTCPListen(ep) else {
            FileHandle.standardError.write(Data("mesh: failed to bind TCP \(ep) — serving UDS only.\n".utf8))
            return
        }
        meshLog("listening on TCP \(ep)")
        let up = "mesh: cross-host TCP listener on \(ep) (UNAUTHENTICATED — Tailscale is the trust boundary)\n"
        FileHandle.standardError.write(Data(up.utf8))
        Thread.detachNewThread { [weak self] in
            while true {
                let cfd = accept(tfd, nil, nil)
                if cfd < 0 { continue }
                Thread.detachNewThread { [weak self] in self?.handle(cfd) }
            }
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
            touchPresenceLocked(n, project: req.project, session: req.session)
            lock.unlock()
            // Hand the joiner the recent conversation so it can catch up.
            return MeshResponse(ok: true, messages: recentTranscript(r, limit: req.limit ?? 30))

        case "history":
            guard let r = req.room else { return .fail("room required") }
            return MeshResponse(ok: true, messages: recentTranscript(r, limit: req.limit ?? 30))

        case "leave":
            guard let r = req.room, let n = req.nick else { return .fail("room and nick required") }
            lock.lock()
            rooms[r]?.members.remove(n)
            rooms[r]?.mailboxes[n] = nil               // leaving abandons that room's unread
            syncUnreadLocked(n)
            touchPresenceLocked(n)
            let wake = waiters.filter { $0.room == r }     // let peers re-evaluate (avoid deadlock)
            lock.unlock()
            for w in wake { w.sem.signal() }
            return .okay()

        case "say":
            guard let r = req.room, let n = req.nick, let t = req.text else { return .fail("room, nick and text required") }
            deliver(room: r, from: n, text: t, to: req.to)
            return .okay()

        case "wait":
            guard let r = req.room, let n = req.nick else { return .fail("room and nick required") }
            return park(room: r, nick: n, timeoutMs: req.timeoutMs ?? 60_000)

        case "peek":
            // Cross-host Stop-hook query: resolve (cwd, session) → nick on the
            // broker (a dial-out host has no local presence/unread files), then
            // return that nick's unread WITHOUT draining. `note` carries the
            // resolved nick so the remote hook can format its block message.
            lock.lock()
            let who = req.nick ?? resolveNickLocked(cwd: req.project, session: req.session)
            guard let n = who else { lock.unlock(); return MeshResponse(ok: true, messages: []) }
            var pending: [MeshMsg] = []
            for (_, room) in rooms {
                if let box = room.mailboxes[n], !box.isEmpty { pending.append(contentsOf: box) }
            }
            pending.sort { $0.ts < $1.ts }
            lock.unlock()
            return MeshResponse(ok: true, messages: pending, note: pending.isEmpty ? nil : n)

        case "recv":
            // Non-blocking drain of the nick's mailboxes across ALL rooms — what
            // the Stop hook tells an agent to run when the signal file is set.
            guard let n = req.nick else { return .fail("nick required") }
            lock.lock()
            var out: [MeshMsg] = []
            for name in rooms.keys {
                if let box = rooms[name]!.mailboxes[n], !box.isEmpty {
                    out.append(contentsOf: box)
                    rooms[name]!.mailboxes[n] = []
                }
            }
            out.sort { $0.ts < $1.ts }
            syncUnreadLocked(n)
            touchPresenceLocked(n)
            lock.unlock()
            return MeshResponse(ok: true, messages: out, note: out.isEmpty ? "idle" : nil)

        case "ask":
            // Send + park for the reply in ONE call, so an agent can't "send and
            // forget to wait" — the act of asking *is* the hanging tool call.
            guard let r = req.room, let n = req.nick, let t = req.text else { return .fail("room, nick and text required") }
            deliver(room: r, from: n, text: t, to: req.to)
            return park(room: r, nick: n, timeoutMs: req.timeoutMs ?? 60_000)

        case "delete":
            guard let r = req.room else { return .fail("room required") }
            lock.lock()
            var affected = Set<String>()
            if let room = rooms[r] { affected.formUnion(room.members); affected.formUnion(room.mailboxes.keys) }
            rooms[r] = nil
            for n in affected { syncUnreadLocked(n); refreshPresenceRoomsLocked(n) }
            writePresenceLocked()
            let wake = waiters.filter { $0.room == r }
            waiters.removeAll { $0.room == r }
            lock.unlock()
            try? FileManager.default.removeItem(at: MeshPaths.transcript(r))
            for w in wake { w.sem.signal() }
            return .okay()

        case "rename":
            // room = old name, text = new name.
            guard let old = req.room, let new = req.text, !new.isEmpty else { return .fail("room and new name required") }
            lock.lock()
            if let existing = rooms[old] { rooms[old] = nil; rooms[new] = existing }
            for n in rooms[new]?.members ?? [] { syncUnreadLocked(n); refreshPresenceRoomsLocked(n) }
            writePresenceLocked()
            let wake = waiters.filter { $0.room == old }
            waiters.removeAll { $0.room == old }
            lock.unlock()
            try? FileManager.default.moveItem(at: MeshPaths.transcript(old), to: MeshPaths.transcript(new))
            for w in wake { w.sem.signal() }
            return .okay()

        case "shutdown":
            // Graceful stop — used when toggling the hub on/off to rebind the
            // listener (UDS-only ↔ UDS+TCP). Reply first, then exit.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { exit(0) }
            return .okay("shutting down")

        default:
            return .fail("unknown cmd: \(req.cmd)")
        }
    }

    /// Post a message: mention-only when `@to` is given, else broadcast to the
    /// rest of the room. Wakes any matching parked waiters.
    private func deliver(room r: String, from n: String, text t: String, to: [String]?) {
        let msg = MeshMsg(from: n, room: r, text: t, ts: Date().timeIntervalSince1970, to: to ?? [])
        var wake: [Waiter] = []
        lock.lock()
        if rooms[r] == nil { rooms[r] = Room() }
        // Mention-only: only @-targets are delivered/woken. A no-mention say is
        // logged to the transcript and wakes nobody. To reach several agents,
        // list them (`@a @b @c`) — there is no `@all`.
        let targets = to ?? []
        for tg in targets { rooms[r]!.mailboxes[tg, default: []].append(msg) }
        for tg in targets { syncUnreadLocked(tg) }     // signal file: the hooks' zero-daemon read
        touchPresenceLocked(n)
        wake = waiters.filter { $0.room == r && targets.contains($0.nick) }
        lock.unlock()
        appendTranscript(msg)
        for w in wake { w.sem.signal() }
    }

    /// Block until a message for `nick` arrives (or timeout). The "park" point:
    /// the connection — hence the agent's Bash tool call — hangs here. A message
    /// queued before the call drains immediately; the mailbox means nothing is
    /// lost across re-parks.
    private func park(room r: String, nick n: String, timeoutMs: Int) -> MeshResponse {
        lock.lock()
        if rooms[r] == nil { rooms[r] = Room(); rooms[r]!.members.insert(n); rooms[r]!.mailboxes[n] = [] }
        rooms[r]!.members.insert(n)
        touchPresenceLocked(n)
        if let box = rooms[r]!.mailboxes[n], !box.isEmpty {
            rooms[r]!.mailboxes[n] = []
            syncUnreadLocked(n)
            lock.unlock()
            return MeshResponse(ok: true, messages: box)
        }
        let w = Waiter(r, n)
        waiters.append(w)
        lock.unlock()

        let res = w.sem.wait(timeout: .now() + .milliseconds(timeoutMs))

        lock.lock()
        waiters.removeAll { $0 === w }
        let msgs = rooms[r]?.mailboxes[n] ?? []
        rooms[r]?.mailboxes[n] = []
        syncUnreadLocked(n)
        lock.unlock()
        if res == .timedOut && msgs.isEmpty {
            return MeshResponse(ok: true, messages: [], note: "timeout")
        }
        return MeshResponse(ok: true, messages: msgs)
    }

    // MARK: mirrored state (call with `lock` held)

    /// Rewrite `nick`'s unread signal file from its in-RAM mailboxes across all
    /// rooms. Empty ⇒ the file is removed, so "file exists" ⇔ "unread pending".
    ///
    /// Invariant: every caller holds `lock`, and the write is rename-atomic, so
    /// a reader always sees a complete snapshot equal to the mailboxes at some
    /// serialized instant. A hook can still *observe* between two delivers and
    /// report a smaller count than a later `recv` drains — that's read timing,
    /// not lost state; the mailbox is authoritative and recv returns all of it.
    private func syncUnreadLocked(_ nick: String) {
        var msgs: [MeshMsg] = []
        for (_, room) in rooms {
            if let box = room.mailboxes[nick], !box.isEmpty { msgs.append(contentsOf: box) }
        }
        let url = MeshPaths.unreadFile(nick)
        guard !msgs.isEmpty else { try? FileManager.default.removeItem(at: url); return }
        msgs.sort { $0.ts < $1.ts }
        var perRoom: [String: Int] = [:]
        for m in msgs { perRoom[m.room, default: 0] += 1 }
        let snap = MeshUnread(v: 1, nick: nick, count: msgs.count, rooms: perRoom,
                              messages: Array(msgs.suffix(50)), updatedTs: Date().timeIntervalSince1970)
        if let d = try? JSONEncoder().encode(snap) { try? d.write(to: url, options: .atomic) }
    }

    /// Bump a nick's presence (lastSeen, membership, optionally its project dir)
    /// and mirror to disk. Skips nicks that are members of nothing and were never
    /// seen — e.g. the GUI's "human" sender — so presence stays a roster of agents.
    private func touchPresenceLocked(_ nick: String, project: String? = nil, session: String? = nil) {
        let memberOf = rooms.filter { $0.value.members.contains(nick) }.map(\.key).sorted()
        if presence[nick] == nil && memberOf.isEmpty { return }
        var e = presence[nick] ?? MeshPresenceEntry(project: nil, session: nil, rooms: [], lastSeen: 0, online: true)
        if let p = project, !p.isEmpty { e.project = p }
        if let s = session, !s.isEmpty { e.session = s }
        e.rooms = memberOf
        e.lastSeen = Date().timeIntervalSince1970
        e.online = true
        presence[nick] = e
        writePresenceLocked()
    }

    /// Broker-side nick resolution from (cwd, session) — mirrors
    /// `MeshHooks.resolveNick` but against in-RAM presence, for the cross-host
    /// `peek`. Session exact-match wins; else longest cwd-prefix, ties → recent.
    private func resolveNickLocked(cwd: String?, session: String?) -> String? {
        if let s = session, !s.isEmpty {
            let hit = presence.filter { $0.value.session == s }
                              .max { $0.value.lastSeen < $1.value.lastSeen }
            if let hit { return hit.key }
        }
        guard let cwd, !cwd.isEmpty else { return nil }
        let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
        var best: (nick: String, plen: Int, seen: Double)?
        for (nick, e) in presence {
            guard let proj = e.project, !proj.isEmpty else { continue }
            let pr = URL(fileURLWithPath: proj).standardizedFileURL.path
            guard path == pr || path.hasPrefix(pr + "/") else { continue }
            if best == nil || pr.count > best!.plen
                || (pr.count == best!.plen && e.lastSeen > best!.seen) {
                best = (nick, pr.count, e.lastSeen)
            }
        }
        return best?.nick
    }

    /// Recompute a nick's room list without bumping lastSeen (room deleted/renamed).
    private func refreshPresenceRoomsLocked(_ nick: String) {
        guard var e = presence[nick] else { return }
        e.rooms = rooms.filter { $0.value.members.contains(nick) }.map(\.key).sorted()
        presence[nick] = e
    }

    private func writePresenceLocked() {
        let snap = MeshPresence(v: 1, nicks: presence)
        if let d = try? JSONEncoder().encode(snap) { try? d.write(to: MeshPaths.presenceFile, options: .atomic) }
    }

    /// The last `limit` messages of a room, from its transcript (the durable log
    /// of everything said, mention or not).
    private func recentTranscript(_ room: String, limit: Int) -> [MeshMsg] {
        guard let data = try? String(contentsOf: MeshPaths.transcript(room), encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        let all = data.split(separator: "\n").compactMap { try? dec.decode(MeshMsg.self, from: Data($0.utf8)) }
        return Array(all.suffix(max(0, limit)))
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
