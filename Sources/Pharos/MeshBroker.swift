import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Wire protocol (newline-delimited JSON over a local unix socket)

struct MeshRequest: Codable {
    var cmd: String                 // create | list | join | leave | say | recv | mark | who | daemon
    var room: String?
    var nick: String?
    var memberID: String?            // immutable delivery identity (normally session id)
    var text: String?
    var to: [String]?               // mention targets; empty/nil = whole room
    var timeoutMs: Int?
    var limit: Int?                 // history / join catch-up size
    var project: String?            // join only: the joiner's cwd, recorded in presence
    var session: String?            // join only: the joiner's CC session id (exact addressing)
    var host: String?               // join only: the joiner's HostIdentity (poke routing)
    var tmuxPane: String?           // join only: the joiner's $TMUX_PANE, when tmux-wrapped
    var state: String?              // mark/peek: hook-reported session state (see MeshSessionState)
    var expectedState: String?      // mark only: compare-and-set guard for observer corrections
    var expectedStateTs: Double?    // mark only: reject a correction if a newer hook already won
    var kind: String?               // join only: "claude" | "codex" (drives the avatar set)
    var tailscaleIP: String?        // join only: the joiner's own `tailscale ip -4`, for SSH auto-fill
}

/// Hook-reported lifecycle states (probed ground truth, cc-hook-probe FINDINGS,
/// re-verified on CC v2.1.207 2026-07-11):
///  busy    — UserPromptSubmit/PostToolUse fired, turn in flight
///  blocked — Notification{permission_prompt|elicitation_dialog}: mid-turn,
///            waiting on the HUMAN — send-keys would type into the dialog
///  stopped — Stop fired: turn over, composer idle → poke-safe
///  idle    — Notification{idle_prompt} (60s after Stop): confirmed idle
///  gone    — SessionEnd: never poke
enum MeshSessionState: String {
    case busy, blocked, stopped, idle, gone
    /// May a send-keys nudge safely reach this session's composer?
    var pokeable: Bool { self == .stopped || self == .idle }
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

/// Per-session unread signal file: a mirror of the member's in-RAM mailboxes across
/// all rooms, rewritten by the broker on every deliver and every drain. The
/// file EXISTS iff something is unread — hooks check it with a pure local read,
/// so a dead broker can never error or trap an agent.
struct MeshUnread: Codable {
    var v: Int
    var memberID: String
    var nick: String
    var count: Int
    var rooms: [String: Int]        // room → unread count
    var messages: [MeshMsg]         // oldest→newest (capped)
    var updatedTs: Double
}

/// session id → runtime identity. `aliases` is room → display nick; aliases are
/// room-scoped and never serve as delivery keys.
struct MeshPresenceEntry: Codable {
    var project: String?
    var session: String?            // CC session id (from --session at join); nil for older/cwd-only joins
    var host: String?               // HostIdentity of the joiner's machine (poke routing); nil pre-0.4 joins
    var tmuxPane: String?           // $TMUX_PANE captured at join; nil = not tmux-wrapped (can't auto-poke)
    var state: String?              // last hook-reported MeshSessionState; nil = unknown (never poke)
    var stateTs: Double?            // when `state` was reported
    var kind: String?               // "claude" | "codex" (avatar set); nil = unknown → claude default
    var tailscaleIP: String?        // the joiner's own `tailscale ip -4`; nil pre-0.5 joins
    var aliases: [String: String]
    var rooms: [String]
    var lastSeen: Double
    var online: Bool
}

/// One member of the mesh as the GUI/CLI sees it — presence plus identity, the
/// unit `who` returns and `say` echoes back for each @-target so the sender can
/// poke (or tell the human to). Field meanings mirror MeshPresenceEntry.
struct MeshMemberInfo: Codable {
    var id: String                  // immutable member/session identity
    var nick: String
    var project: String?
    var session: String?
    var host: String?
    var tmuxPane: String?
    var state: String?
    var stateTs: Double?
    var unread: Int?                // pending mailbox messages across all rooms
    var kind: String?               // "claude" | "codex" — which avatar set the GUI shows
    var tailscaleIP: String?        // the member's own `tailscale ip -4`, for SSH host auto-fill
    var rooms: [String]
    var lastSeen: Double
}

struct MeshPresence: Codable {
    var v: Int
    var members: [String: MeshPresenceEntry]
}

struct MeshResponse: Codable {
    var ok: Bool
    var error: String?
    var rooms: [MeshRoomInfo]?
    var messages: [MeshMsg]?
    var members: [MeshMemberInfo]?  // who: full roster; say: the @-targets' presence
    var note: String?
    var memberID: String?
    var payload: String?            // projects/issues: registry JSON the hub is the source of truth for

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

    /// Where CLIENTS (CLI, hooks) should dial: the env override first, else the
    /// app-managed `mesh-endpoint` file. The file is written by the GUI when this
    /// Mac pairs to a remote hub, so satellite agents follow the hub with zero
    /// per-agent env config (Pharos#5 P3). Dial-only — the broker's *bind*
    /// decision stays env-only (`tcpEndpoint`), or a satellite would try to bind
    /// the hub's address.
    static var endpointFile: URL { supportDir.appendingPathComponent("mesh-endpoint") }
    static var dialEndpoint: String? {
        if let env = tcpEndpoint { return env }
        guard let raw = try? String(contentsOf: endpointFile, encoding: .utf8) else { return nil }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return meshSplitHostPort(v) != nil ? v : nil
    }
    static func setDialEndpointFile(_ ep: String?) {
        if let ep, !ep.isEmpty {
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try? (ep + "\n").write(to: endpointFile, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: endpointFile)
        }
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

    /// PostToolUse de-dup marker: the newest unread timestamp already surfaced
    /// mid-turn for a nick, so consecutive tool calls don't repeat the notice.
    static func notifiedFile(_ memberID: String) -> URL {
        let safe = String(memberID.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
        return stateDir.appendingPathComponent("notified-\(safe)")
    }
    static func unreadFile(_ memberID: String) -> URL {
        let safe = String(memberID.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
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

/// In-memory chat broker. Holds rooms → members → per-member durable mailboxes,
/// mirrors each nick's unread to a signal file for the hooks, and appends every
/// message to a per-room transcript file for the GUI to read. Delivery to an agent
/// is by @mention into its mailbox; the Stop hook surfaces it at the next turn.
final class MeshBroker {
    private let lock = NSLock()
    /// alias → immutable member id; mailboxes are keyed only by member id.
    private struct Room { var members: [String: String] = [:]; var mailboxes: [String: [MeshMsg]] = [:] }
    private var rooms: [String: Room] = [:]
    private var presence: [String: MeshPresenceEntry] = [:]

    static func runDaemon() -> Never {
        let broker = MeshBroker() // keep strong lifetime for weak listener closures
        broker.serve()
        exit(0)   // unreachable
    }

    /// Observer-driven corrections use compare-and-set semantics: a hook event
    /// that lands after the observer's snapshot must never be overwritten.
    static func markMatchesSnapshot(_ entry: MeshPresenceEntry, request: MeshRequest) -> Bool {
        (request.expectedState == nil || entry.state == request.expectedState)
            && (request.expectedStateTs == nil || entry.stateTs == request.expectedStateTs)
    }

    func serve() {
        signal(SIGPIPE, SIG_IGN)        // a hung-up client must not kill the daemon
        try? FileManager.default.createDirectory(at: MeshPaths.supportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: MeshPaths.transcriptDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: MeshPaths.unreadDir, withIntermediateDirectories: true)
        // Fresh broker = fresh MAILBOXES: reset the unread signal files so hooks
        // never see a signal this broker didn't write. Transcripts are durable.
        if let stale = try? FileManager.default.contentsOfDirectory(at: MeshPaths.unreadDir, includingPropertiesForKeys: nil) {
            for f in stale { try? FileManager.default.removeItem(at: f) }
        }
        // But RESTORE registration identity (session → host/pane/project +
        // room membership) from the previous broker's presence mirror. Without
        // this, a broker restart stranded every joined agent: hooks resolve
        // nicks via presence, so delivery/state/avatars all went dark (gray)
        // until each agent manually re-joined (observed 2026-07-11). States are
        // dropped — a stale busy/idle must never steer a poke; the agent's next
        // hook event repopulates them.
        if let d = try? Data(contentsOf: MeshPaths.presenceFile),
           let prev = try? JSONDecoder().decode(MeshPresence.self, from: d) {
            for (memberID, entry) in prev.members {
                var e = entry
                e.state = nil
                e.stateTs = nil
                presence[memberID] = e
                for (r, alias) in e.aliases {
                    if rooms[r] == nil { rooms[r] = Room() }
                    rooms[r]!.members[alias] = memberID
                    if rooms[r]!.mailboxes[memberID] == nil { rooms[r]!.mailboxes[memberID] = [] }
                }
            }
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

    func process(_ req: MeshRequest) -> MeshResponse {
        switch req.cmd {
        case "create":
            guard let r = req.room else { return .fail("room required") }
            lock.lock(); if rooms[r] == nil { rooms[r] = Room() }; lock.unlock()
            return .okay()

        case "list":
            lock.lock()
            var info = rooms.map { MeshRoomInfo(name: $0.key, members: $0.value.members.keys.sorted()) }
            lock.unlock()
            // Rooms are RAM, transcripts are disk: after a broker restart the
            // registry is empty but every room's history still exists. List
            // transcript-backed rooms too (no members yet), so chat history
            // survives restarts in the GUI and `history`/`join` keep working.
            let known = Set(info.map(\.name))
            if let files = try? FileManager.default.contentsOfDirectory(at: MeshPaths.transcriptDir,
                                                                        includingPropertiesForKeys: nil) {
                for f in files where f.pathExtension == "jsonl" {
                    let name = f.deletingPathExtension().lastPathComponent
                    if !name.isEmpty && !known.contains(name) {
                        info.append(MeshRoomInfo(name: name, members: []))
                    }
                }
            }
            return MeshResponse(ok: true, rooms: info.sorted { $0.name < $1.name })

        case "join":
            guard let r = req.room, let n = req.nick,
                  let memberID = req.session, !memberID.isEmpty else {
                return .fail("room, nick, and session required")
            }
            lock.lock()
            if rooms[r] == nil { rooms[r] = Room() }
            // A restarted session may reclaim the same room-local alias. Move
            // pending mail to it, but never disturb that alias in other rooms.
            if let oldID = rooms[r]!.members[n], oldID != memberID {
                let pending = rooms[r]!.mailboxes.removeValue(forKey: oldID) ?? []
                rooms[r]!.mailboxes[memberID, default: []].append(contentsOf: pending)
                rooms[r]!.members[n] = memberID
                syncUnreadLocked(oldID)
                refreshPresenceRoomsLocked(oldID)
            } else {
                rooms[r]!.members[n] = memberID
            }
            if rooms[r]!.mailboxes[memberID] == nil { rooms[r]!.mailboxes[memberID] = [] }
            // A joining agent is mid-turn by definition (the CLI runs in its
            // Bash tool) — seed state busy until its hooks report otherwise.
            touchPresenceLocked(memberID, project: req.project, session: req.session,
                                host: req.host, tmuxPane: req.tmuxPane,
                                state: MeshSessionState.busy.rawValue, kind: req.kind,
                                tailscaleIP: req.tailscaleIP)
            syncUnreadLocked(memberID)
            lock.unlock()
            // Hand the joiner the recent conversation so it can catch up.
            return MeshResponse(ok: true, messages: recentTranscript(r, limit: req.limit ?? 30))

        case "history":
            guard let r = req.room else { return .fail("room required") }
            return MeshResponse(ok: true, messages: recentTranscript(r, limit: req.limit ?? 30))

        case "leave":
            guard let r = req.room, let n = req.nick else { return .fail("room and nick required") }
            lock.lock()
            if let memberID = rooms[r]?.members.removeValue(forKey: n) {
                rooms[r]?.mailboxes[memberID] = nil    // leaving abandons that room's unread
                syncUnreadLocked(memberID)
                refreshPresenceRoomsLocked(memberID)
                writePresenceLocked()
            }
            lock.unlock()
            return .okay()

        case "say":
            guard let r = req.room, let n = req.nick, let t = req.text else { return .fail("room, nick and text required") }
            deliver(room: r, from: n, text: t, to: req.to)
            // Echo EVERY @-target's presence so the sender can act on delivery:
            // poke a stopped/idle tmux session, tell the human to nudge a
            // session we can't reach (no pane / blocked on a dialog) — and an
            // UNREGISTERED nick gets a bare placeholder, so mentioning someone
            // who never joined (or whose registration was lost) is never silent.
            lock.lock()
            let targetInfo = (req.to ?? []).map { nick in
                memberInfoLocked(room: r, nick: nick)
                    ?? MeshMemberInfo(id: "", nick: nick, project: nil, session: nil, host: nil,
                                      tmuxPane: nil, state: nil, stateTs: nil, unread: nil,
                                      kind: nil, tailscaleIP: nil, rooms: [], lastSeen: 0)
            }
            lock.unlock()
            return MeshResponse(ok: true, members: targetInfo.isEmpty ? nil : targetInfo)

        case "mark":
            // Hook-reported session state (fire-and-forget from the reporter's
            // point of view). Resolve the agent by explicit nick, else by
            // (session, cwd) — same rules as peek. Unknown agent = silently ok:
            // a hook must never propagate an error back into a session.
            guard let s = req.state, MeshSessionState(rawValue: s) != nil else { return .fail("valid state required") }
            lock.lock()
            if let memberID = resolveMemberIDLocked(request: req),
               presence[memberID] != nil,
               Self.markMatchesSnapshot(presence[memberID]!, request: req) {
                presence[memberID]!.state = s
                presence[memberID]!.stateTs = Date().timeIntervalSince1970
                writePresenceLocked()
            }
            lock.unlock()
            return .okay()

        case "who":
            lock.lock()
            let roster = rooms.keys.sorted().flatMap { room in
                rooms[room]!.members.keys.sorted().compactMap { memberInfoLocked(room: room, nick: $0) }
            }
            lock.unlock()
            return MeshResponse(ok: true, members: roster)

        case "projects":
            // The hub is the single source of truth for the project registry.
            // Clients read it over this connection instead of iCloud or per-client SSH.
            return MeshResponse(ok: true, payload: registryProjectsJSON())

        case "issues":
            return MeshResponse(ok: true, payload: registryIssuesJSON())

        case "peek":
            // Cross-host Stop-hook query: resolve (cwd, session) → nick on the
            // broker (a dial-out host has no local presence/unread files), then
            // return that nick's unread WITHOUT draining. `note` carries the
            // resolved nick so the remote hook can format its block message.
            // A `state` in the request piggybacks the hook's state report
            // (e.g. the Stop hook marks `stopped`) on the same round-trip.
            lock.lock()
            guard let memberID = resolveMemberIDLocked(request: req) else {
                lock.unlock(); return MeshResponse(ok: true, messages: [])
            }
            if let s = req.state, MeshSessionState(rawValue: s) != nil, presence[memberID] != nil {
                presence[memberID]!.state = s
                presence[memberID]!.stateTs = Date().timeIntervalSince1970
                writePresenceLocked()
            }
            var pending: [MeshMsg] = []
            for (_, room) in rooms {
                if let box = room.mailboxes[memberID], !box.isEmpty { pending.append(contentsOf: box) }
            }
            pending.sort { $0.ts < $1.ts }
            lock.unlock()
            let alias = pending.first.flatMap { presence[memberID]?.aliases[$0.room] }
                ?? presence[memberID]?.aliases.values.sorted().first
            return MeshResponse(ok: true, messages: pending, note: pending.isEmpty ? nil : alias,
                                memberID: memberID)

        case "recv":
            // Non-blocking drain of the nick's mailboxes across ALL rooms — what
            // the Stop hook tells an agent to run when the signal file is set.
            lock.lock()
            guard let memberID = resolveMemberIDLocked(request: req) else {
                lock.unlock(); return .fail("member not found")
            }
            var out: [MeshMsg] = []
            for name in rooms.keys {
                if let box = rooms[name]!.mailboxes[memberID], !box.isEmpty {
                    out.append(contentsOf: box)
                    rooms[name]!.mailboxes[memberID] = []
                }
            }
            out.sort { $0.ts < $1.ts }
            syncUnreadLocked(memberID)
            // recv runs inside the agent's Bash tool → it's mid-turn right now.
            touchPresenceLocked(memberID, state: MeshSessionState.busy.rawValue)
            lock.unlock()
            return MeshResponse(ok: true, messages: out, note: out.isEmpty ? "idle" : nil)

        case "delete":
            guard let r = req.room else { return .fail("room required") }
            lock.lock()
            var affected = Set<String>()
            if let room = rooms[r] { affected.formUnion(room.members.values); affected.formUnion(room.mailboxes.keys) }
            rooms[r] = nil
            for n in affected { syncUnreadLocked(n); refreshPresenceRoomsLocked(n) }
            writePresenceLocked()
            lock.unlock()
            try? FileManager.default.removeItem(at: MeshPaths.transcript(r))
            return .okay()

        case "rename":
            // room = old name, text = new name.
            guard let old = req.room, let new = req.text, !new.isEmpty else { return .fail("room and new name required") }
            lock.lock()
            if let existing = rooms[old] { rooms[old] = nil; rooms[new] = existing }
            for memberID in rooms[new]?.members.values ?? Dictionary<String, String>().values {
                syncUnreadLocked(memberID); refreshPresenceRoomsLocked(memberID)
            }
            writePresenceLocked()
            lock.unlock()
            try? FileManager.default.moveItem(at: MeshPaths.transcript(old), to: MeshPaths.transcript(new))
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

    /// Post a message (delivery model B, 2026-07-13):
    ///  • `@mention`  → DIRECTED: the named agents get it, and it pokes them
    ///    (a directed message carries a non-empty `to`).
    ///  • no mention  → BROADCAST: every OTHER room member gets it in their
    ///    mailbox (carries an empty `to`), so everyone receives it — but it does
    ///    NOT poke; each recipient sees it at its next turn boundary (Stop hook).
    /// The empty-vs-non-empty `to` on the stored `MeshMsg` is exactly what the
    /// poke path keys on, so no separate flag is needed.
    private func deliver(room r: String, from n: String, text t: String, to: [String]?) {
        let msg = MeshMsg(from: n, room: r, text: t, ts: Date().timeIntervalSince1970, to: to ?? [])
        lock.lock()
        if rooms[r] == nil { rooms[r] = Room() }
        let targetIDs: [String]
        if let to, !to.isEmpty {
            targetIDs = to.compactMap { rooms[r]!.members[$0] }   // resolve aliases inside THIS room
        } else {
            // Broadcast → everyone in the room except the sender (and never the
            // human, who reads the transcript in the GUI and has no mailbox/hook).
            targetIDs = rooms[r]!.members
                .filter { $0.key != n && $0.key != "human" }.map(\.value).sorted()
        }
        for memberID in targetIDs { rooms[r]!.mailboxes[memberID, default: []].append(msg) }
        for memberID in targetIDs { syncUnreadLocked(memberID) }
        if let senderID = rooms[r]!.members[n] { touchPresenceLocked(senderID) }
        lock.unlock()
        appendTranscript(msg)
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
    private func syncUnreadLocked(_ memberID: String) {
        var msgs: [MeshMsg] = []
        for (_, room) in rooms {
            if let box = room.mailboxes[memberID], !box.isEmpty { msgs.append(contentsOf: box) }
        }
        let url = MeshPaths.unreadFile(memberID)
        guard !msgs.isEmpty else { try? FileManager.default.removeItem(at: url); return }
        msgs.sort { $0.ts < $1.ts }
        var perRoom: [String: Int] = [:]
        for m in msgs { perRoom[m.room, default: 0] += 1 }
        let alias = msgs.first.flatMap { presence[memberID]?.aliases[$0.room] }
            ?? presence[memberID]?.aliases.values.sorted().first ?? "agent"
        let snap = MeshUnread(v: 2, memberID: memberID, nick: alias, count: msgs.count, rooms: perRoom,
                              messages: Array(msgs.suffix(50)), updatedTs: Date().timeIntervalSince1970)
        if let d = try? JSONEncoder().encode(snap) { try? d.write(to: url, options: .atomic) }
    }

    /// Bump a nick's presence (lastSeen, membership, optionally its project dir /
    /// host / tmux pane / state) and mirror to disk. Skips nicks that are members
    /// of nothing and were never seen — e.g. the GUI's "human" sender — so
    /// presence stays a roster of agents.
    private func touchPresenceLocked(_ memberID: String, project: String? = nil, session: String? = nil,
                                     host: String? = nil, tmuxPane: String? = nil, state: String? = nil,
                                     kind: String? = nil, tailscaleIP: String? = nil) {
        let aliases = Dictionary(uniqueKeysWithValues: rooms.compactMap { room, value in
            value.members.first(where: { $0.value == memberID }).map { (room, $0.key) }
        })
        if presence[memberID] == nil && aliases.isEmpty { return }
        var e = presence[memberID] ?? MeshPresenceEntry(project: nil, session: nil, host: nil, tmuxPane: nil,
                                                        state: nil, stateTs: nil, kind: nil, tailscaleIP: nil,
                                                        aliases: [:], rooms: [], lastSeen: 0, online: true)
        if let p = project, !p.isEmpty { e.project = p }
        if let s = session, !s.isEmpty { e.session = s }
        if let h = host, !h.isEmpty { e.host = h }
        if let k = kind, !k.isEmpty { e.kind = k }
        if let ip = tailscaleIP, !ip.isEmpty { e.tailscaleIP = ip }
        // A re-join OUTSIDE tmux must clear a stale pane from an earlier
        // tmux-wrapped join, so join always overwrites (nil included) when it
        // carries identity; plain touches (say/recv) leave it alone.
        if session != nil || project != nil { e.tmuxPane = tmuxPane }
        if let st = state {
            e.state = st
            e.stateTs = Date().timeIntervalSince1970
        }
        e.aliases = aliases
        e.rooms = aliases.keys.sorted()
        e.lastSeen = Date().timeIntervalSince1970
        e.online = true
        presence[memberID] = e
        writePresenceLocked()
    }

    /// Presence entry → the wire shape `who`/`say` return. Call with `lock` held.
    /// `unread` counts only DIRECTED (@mention) messages — broadcasts (empty
    /// `to`) are delivered but must never trigger a poke, so the sweeper, which
    /// keys on this count, leaves broadcast-only recipients alone.
    private func memberInfoLocked(room: String, nick: String) -> MeshMemberInfo? {
        guard let memberID = rooms[room]?.members[nick], let e = presence[memberID] else { return nil }
        let unread = rooms.values.reduce(0) { acc, room in
            let alias = room.members.first(where: { $0.value == memberID })?.key
            return acc + (room.mailboxes[memberID]?.filter { alias.map($0.to.contains) ?? false }.count ?? 0)
        }
        return MeshMemberInfo(id: memberID, nick: nick, project: e.project, session: e.session, host: e.host,
                              tmuxPane: e.tmuxPane, state: e.state, stateTs: e.stateTs,
                              unread: unread, kind: e.kind, tailscaleIP: e.tailscaleIP,
                              rooms: [room], lastSeen: e.lastSeen)
    }

    // MARK: - Registry (the hub is the source of truth; clients read over mesh)

    /// All registered projects as JSON matching the mobile parser
    /// (`{"projects":[{name, localPath, githubRemote, tags}]}`).
    private func registryProjectsJSON() -> String {
        let rows: [[String: Any]] = PharosCore.loadProjects().map { p in
            ["name": p.name,
             "localPath": p.localPath ?? NSNull(),
             "githubRemote": p.githubRemote ?? NSNull(),
             "tags": p.tags]
        }
        return Self.jsonString(["projects": rows]) ?? #"{"projects":[]}"#
    }

    /// Every open issue across all projects
    /// (`{"issues":[{project, number, title, status, priority, labels}]}`).
    private func registryIssuesJSON() -> String {
        var out: [[String: Any]] = []
        for p in PharosCore.loadProjects() {
            for i in p.issues where i.status.isOpen {
                out.append(["project": p.name, "number": i.number, "title": i.title,
                            "status": i.status.rawValue, "priority": i.priority.rawValue, "labels": i.labels])
            }
        }
        return Self.jsonString(["issues": out]) ?? #"{"issues":[]}"#
    }

    private static func jsonString(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Broker-side nick resolution from (cwd, session) — mirrors
    /// `MeshHooks.resolveNick` (INCLUDING its identity rule: entries that
    /// declared a session are never cwd-claimed by other sessions) but against
    /// in-RAM presence, for the cross-host `peek`/`mark`.
    private func resolveMemberIDLocked(request req: MeshRequest) -> String? {
        if let id = req.memberID, presence[id] != nil { return id }
        if let s = req.session, !s.isEmpty {
            if presence[s] != nil { return s }
            if let hit = presence.first(where: { $0.value.session == s }) { return hit.key }
            return nil
        }
        if let room = req.room, let nick = req.nick, let id = rooms[room]?.members[nick] { return id }
        guard let cwd = req.project, !cwd.isEmpty else {
            // Manual compatibility: accept an alias only when globally unique.
            guard let nick = req.nick else { return nil }
            let ids = Set(rooms.values.compactMap { $0.members[nick] })
            return ids.count == 1 ? ids.first : nil
        }
        let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
        var best: (id: String, plen: Int, seen: Double)?
        for (id, e) in presence {
            if let nick = req.nick, !e.aliases.values.contains(nick) { continue }
            guard let proj = e.project, !proj.isEmpty else { continue }
            let pr = URL(fileURLWithPath: proj).standardizedFileURL.path
            guard path == pr || path.hasPrefix(pr + "/") else { continue }
            if best == nil || pr.count > best!.plen
                || (pr.count == best!.plen && e.lastSeen > best!.seen) {
                best = (id, pr.count, e.lastSeen)
            }
        }
        return best?.id
    }

    /// Recompute a nick's room list without bumping lastSeen (room deleted/renamed).
    private func refreshPresenceRoomsLocked(_ memberID: String) {
        guard var e = presence[memberID] else { return }
        e.aliases = Dictionary(uniqueKeysWithValues: rooms.compactMap { room, value in
            value.members.first(where: { $0.value == memberID }).map { (room, $0.key) }
        })
        e.rooms = e.aliases.keys.sorted()
        if e.aliases.isEmpty {
            presence.removeValue(forKey: memberID)
            try? FileManager.default.removeItem(at: MeshPaths.unreadFile(memberID))
            try? FileManager.default.removeItem(at: MeshPaths.notifiedFile(memberID))
            return
        }
        presence[memberID] = e
    }

    private func writePresenceLocked() {
        let snap = MeshPresence(v: 2, members: presence)
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
