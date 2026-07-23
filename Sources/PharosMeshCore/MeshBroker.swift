import Foundation
import Crypto
import PharosMeshProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Shared legacy wire values live in PharosMeshProtocol.

// MARK: - Paths (socket is always local; durable Broker data lives in the configured data directory)

public enum MeshPaths {
    /// Always-local Pharos app-support dir (never iCloud — a socket can't live in
    /// iCloud). `PHAROS_MESH_DIR` overrides it so tests can run a hermetic broker
    /// without touching the live one (mirrors `PHAROS_REGISTRY`).
    public static var supportDir: URL {
        if let o = ProcessInfo.processInfo.environment["PHAROS_MESH_DIR"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true)
        }
        #if os(Linux)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".local/share/pharos", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Pharos", isDirectory: true)
        #endif
    }
    public static var socketPath: String { supportDir.appendingPathComponent("mesh.sock").path }
    public static var daemonLog: URL { supportDir.appendingPathComponent("mesh-daemon.log") }

    /// Cross-host transport (see MeshTCP.swift). `PHAROS_MESH_TCP=host:port`
    /// makes the broker also listen on TCP and clients dial it instead of the
    /// local UDS. Unauthenticated (Tailscale is the trust boundary), so the
    /// broker refuses to bind unless `PHAROS_MESH_TCP_INSECURE=1` is also set.
    public static var tcpEndpoint: String? {
        guard let v = ProcessInfo.processInfo.environment["PHAROS_MESH_TCP"], !v.isEmpty else { return nil }
        return v
    }
    public static var tcpInsecureOptIn: Bool {
        ProcessInfo.processInfo.environment["PHAROS_MESH_TCP_INSECURE"] == "1"
    }

    /// Where CLIENTS (CLI, hooks) should dial: the env override first, else the
    /// app-managed `mesh-endpoint` file. The file is written by the GUI when this
    /// Mac pairs to a remote hub, so satellite agents follow the hub with zero
    /// per-agent env config (Pharos#5 P3). Dial-only — the broker's *bind*
    /// decision stays env-only (`tcpEndpoint`), or a satellite would try to bind
    /// the hub's address.
    public static var endpointFile: URL { supportDir.appendingPathComponent("mesh-endpoint") }
    public static var controlTokenFile: URL { supportDir.appendingPathComponent("mesh-control-token") }
    public static var brokerControlTokenFile: URL { dataDirectory.appendingPathComponent("mesh-control-token") }
    public static var nodeCommandsFile: URL { dataDirectory.appendingPathComponent("mesh-node-commands.json") }
    public static var mailboxesFile: URL { dataDirectory.appendingPathComponent("mesh-mailboxes.json") }
    public static var dialEndpoint: String? {
        if let env = tcpEndpoint { return env }
        guard let raw = try? String(contentsOf: endpointFile, encoding: .utf8) else { return nil }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return meshSplitHostPort(v) != nil ? v : nil
    }
    public static func setDialEndpointFile(_ ep: String?) {
        if let ep, !ep.isEmpty {
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try? (ep + "\n").write(to: endpointFile, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: endpointFile)
        }
    }

    public static var controlToken: String? {
        guard let raw = try? String(contentsOf: controlTokenFile, encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count >= 32 ? value : nil
    }

    public static func setControlTokenFile(_ token: String?) {
        if let token, token.count >= 32 {
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try? (token + "\n").write(to: controlTokenFile, atomically: true, encoding: .utf8)
            #if !os(Windows)
            chmod(controlTokenFile.path, 0o600)
            #endif
        } else {
            try? FileManager.default.removeItem(at: controlTokenFile)
        }
    }

    /// Darwin's `sun_path` holds 104 bytes including the NUL — a longer socket
    /// path silently truncates in `meshFillSockaddr` and binds/connects somewhere
    /// unintended. Non-nil = the clear diagnostic to surface instead.
    public static var socketPathOverflow: String? {
        let n = socketPath.utf8.count
        guard n > 103 else { return nil }
        return "mesh socket path too long: \(socketPath) (\(n) chars > 103) — set a shorter PHAROS_MESH_DIR"
    }

    /// Local-only mesh runtime state (never iCloud): per-nick unread signal
    /// files + presence. Mirrors the broker's RAM, so a fresh daemon wipes it —
    /// the hooks must never read a signal the current broker didn't write.
    public static var stateDir: URL { supportDir.appendingPathComponent("mesh-state", isDirectory: true) }
    public static var unreadDir: URL { stateDir.appendingPathComponent("unread", isDirectory: true) }
    public static var presenceFile: URL { stateDir.appendingPathComponent("presence.json") }

    /// PostToolUse de-dup marker: the newest unread timestamp already surfaced
    /// mid-turn for a nick, so consecutive tool calls don't repeat the notice.
    public static func notifiedFile(_ memberID: String) -> URL {
        let safe = String(memberID.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
        return stateDir.appendingPathComponent("notified-\(safe)")
    }
    public static func unreadFile(_ memberID: String) -> URL {
        let safe = String(memberID.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
        return unreadDir.appendingPathComponent("\(safe).json")
    }

    /// Durable Broker data is separate from the client's local cache even when
    /// both run on one Mac; otherwise a cache write would bypass registry CAS.
    public static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PHAROS_MESH_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let registry = ProcessInfo.processInfo.environment["PHAROS_REGISTRY"], !registry.isEmpty {
            return URL(fileURLWithPath: registry).deletingLastPathComponent()
        }
        return supportDir.appendingPathComponent("broker-data", isDirectory: true)
    }
    public static var transcriptDir: URL { dataDirectory.appendingPathComponent("mesh", isDirectory: true) }
    public static var attachmentDir: URL { transcriptDir.appendingPathComponent("attachments", isDirectory: true) }
    public static var registryFile: URL { dataDirectory.appendingPathComponent("projects.json") }
    public static var brokerIDFile: URL { dataDirectory.appendingPathComponent("broker-id") }
    public static var registryBackupDir: URL {
        dataDirectory.appendingPathComponent("registry-backups", isDirectory: true)
    }

    public static func transcript(_ room: String) -> URL {
        transcriptDir.appendingPathComponent("\(room).jsonl")
    }

    public static func attachmentDirectory(_ id: String) -> URL {
        attachmentDir.appendingPathComponent(safePathComponent(id), isDirectory: true)
    }

    public static func attachmentData(_ id: String) -> URL {
        attachmentDirectory(id).appendingPathComponent("data")
    }

    public static func attachmentMetadata(_ id: String) -> URL {
        attachmentDirectory(id).appendingPathComponent("metadata.json")
    }

    private static func safePathComponent(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
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

func meshWriteRaw(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard var pointer = raw.baseAddress else { return }
        var remaining = raw.count
        while remaining > 0 {
            let count = write(fd, pointer, remaining)
            if count <= 0 { break }
            pointer = pointer.advanced(by: count)
            remaining -= count
        }
    }
}

func meshReadExactly(_ fd: Int32, count: Int) -> Data? {
    guard count >= 0 else { return nil }
    var output = Data()
    output.reserveCapacity(count)
    var remaining = count
    var buffer = [UInt8](repeating: 0, count: min(64 * 1024, max(1, count)))
    while remaining > 0 {
        let requested = min(remaining, buffer.count)
        let received = read(fd, &buffer, requested)
        if received <= 0 { return nil }
        output.append(buffer, count: received)
        remaining -= received
    }
    return output
}

// MARK: - Broker daemon

/// In-memory chat broker. Holds rooms → members → per-member durable mailboxes,
/// mirrors each nick's unread to a signal file for the hooks, and appends every
/// message to a per-room transcript file for the GUI to read. Delivery to an agent
/// is by @mention into its mailbox; the Stop hook surfaces it at the next turn.
public final class MeshBroker: @unchecked Sendable {
    private let lock = NSLock()
    private let eventCondition = NSCondition()
    private var eventSequence: UInt64 = 0
    private var events: [MeshEvent] = []
    private let maximumEvents = 2_000
    /// alias → immutable member id; mailboxes are keyed only by member id.
    private struct Room: Codable { var members: [String: String] = [:]; var mailboxes: [String: [MeshMsg]] = [:] }
    private var rooms: [String: Room] = [:]
    private var presence: [String: MeshPresenceEntry] = [:]
    private var pairingTokens: [String: Double] = [:]
    private var nodes: [String: MeshNodeInfo] = [:]
    private var nodeCommands: [MeshNodeCommand] = []
    private var cachedBrokerID: String?
    private var cachedControlToken: String?

    public init(loadPersistentState: Bool = false) {
        if loadPersistentState {
            loadNodeCommandsLocked()
            loadMailboxesLocked()
            loadPresenceLocked(resetStates: true)
        }
    }

    public static func runDaemon() -> Never {
        let broker = MeshBroker(loadPersistentState: true) // keep strong lifetime for weak listener closures
        broker.serve()
        exit(0)   // unreachable
    }

    /// Observer-driven corrections use compare-and-set semantics: a hook event
    /// that lands after the observer's snapshot must never be overwritten.
    public static func markMatchesSnapshot(_ entry: MeshPresenceEntry, request: MeshRequest) -> Bool {
        (request.expectedState == nil || entry.state == request.expectedState)
            && (request.expectedStateTs == nil || entry.stateTs == request.expectedStateTs)
    }

    public func serve() {
        signal(SIGPIPE, SIG_IGN)        // a hung-up client must not kill the daemon
        migrateLegacyLocalBrokerDataIfNeeded()
        try? FileManager.default.createDirectory(at: MeshPaths.supportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: MeshPaths.transcriptDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: MeshPaths.attachmentDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: MeshPaths.registryBackupDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: MeshPaths.unreadDir, withIntermediateDirectories: true)
        _ = controlToken() // local Host nodes may dial this Broker's TCP endpoint
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
        // dropped to unknown on restart. Unknown is an expired lease and may
        // be poked; the agent's next hook event repopulates exact state.
        for memberID in presence.keys { syncUnreadLocked(memberID) }
        writeMailboxesLocked()
        writePresenceLocked()

        let path = MeshPaths.socketPath
        if let e = MeshPaths.socketPathOverflow {
            FileHandle.standardError.write(Data((e + "\n").utf8))
            exit(1)
        }
        if let fd = MeshClient.connectUDS() { close(fd); exit(0) }   // a daemon already serves here — defer
        unlink(path)
        let sfd = socket(AF_UNIX, meshSocketStream(), 0)
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
            Thread.detachNewThread { [weak self] in self?.handle(cfd, trustedLocal: true) }
        }
    }

    private func migrateLegacyLocalBrokerDataIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PHAROS_MESH_DATA_DIR"] == nil,
              environment["PHAROS_REGISTRY"] == nil,
              !FileManager.default.fileExists(atPath: MeshPaths.dataDirectory.path) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: MeshPaths.dataDirectory, withIntermediateDirectories: true)
        for name in ["projects.json", "mesh"] {
            let source = MeshPaths.supportDir.appendingPathComponent(name)
            let destination = MeshPaths.dataDirectory.appendingPathComponent(name)
            if fm.fileExists(atPath: source.path), !fm.fileExists(atPath: destination.path) {
                try? fm.copyItem(at: source, to: destination)
            }
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
        let up = "mesh: cross-host TCP listener on \(ep) (control API authenticated; Tailscale-only transport recommended)\n"
        FileHandle.standardError.write(Data(up.utf8))
        Thread.detachNewThread { [weak self] in
            while true {
                let cfd = accept(tfd, nil, nil)
                if cfd < 0 { continue }
                Thread.detachNewThread { [weak self] in self?.handle(cfd, trustedLocal: false) }
            }
        }
    }

    private func handle(_ cfd: Int32, trustedLocal: Bool) {
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
        if req.cmd == "attachment-put" {
            handleAttachmentUpload(cfd, request: req)
            return
        }
        if req.cmd == "attachment-get" {
            handleAttachmentDownload(cfd, request: req)
            return
        }
        let resp = process(req, trustedLocal: trustedLocal) // for `wait`, this blocks until ready
        if let d = try? JSONEncoder().encode(resp) { meshWriteAll(cfd, d); meshLog("response written ok=\(resp.ok)") }
    }

    public func process(_ req: MeshRequest, trustedLocal: Bool = true) -> MeshResponse {
        switch req.cmd {
        case "capabilities":
            return MeshResponse(ok: true, capabilities: [
                "mesh-v2", "message-id", "reply-v1", "attachment-v1", "headless-v1",
                "registry-cas-v1", "pairing-v2", "events-v1", "node-v2",
                "session-sender-v1", "history-page-v1"
            ])

        case "events":
            return waitForEvents(after: req.cursor, timeoutMs: req.timeoutMs)

        case "node-heartbeat":
            guard authorizeControl(req, trustedLocal: trustedLocal) else {
                return .fail("valid control credential required")
            }
            guard let id = req.memberID, !id.isEmpty, let host = req.host, !host.isEmpty else {
                return .fail("node id and host required")
            }
            lock.lock()
            nodes[id] = MeshNodeInfo(id: id, host: host, tailscaleIP: req.tailscaleIP,
                                     lastSeen: Date().timeIntervalSince1970, buildID: req.payload)
            pruneNodesLocked()
            lock.unlock()
            recoverUnreadPokes(nodeID: id, host: host, tailscaleIP: req.tailscaleIP)
            return .okay()

        case "node-command-enqueue":
            guard authorizeControl(req, trustedLocal: trustedLocal) else {
                return .fail("valid control credential required")
            }
            guard let nodeID = req.nodeID, !nodeID.isEmpty,
                  let rawAction = req.action, let action = MeshNodeCommandAction(rawValue: rawAction) else {
                return .fail("node id and allow-listed action required")
            }
            let now = Date().timeIntervalSince1970
            let deadline = min(req.deadline ?? now + 3_600, now + 86_400)
            guard deadline > now else { return .fail("command deadline must be in the future") }
            let key = req.idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key, !key.isEmpty, key.count <= 200 else {
                return .fail("idempotency key required")
            }
            lock.lock()
            expireNodeCommandsLocked(now: now)
            if let existing = nodeCommands.first(where: { $0.nodeID == nodeID && $0.idempotencyKey == key }) {
                lock.unlock()
                return MeshResponse(ok: true, command: existing)
            }
            let command = MeshNodeCommand(nodeID: nodeID, action: action, payload: req.payload,
                                          idempotencyKey: key, deadline: deadline,
                                          maxAttempts: min(1_000, max(1, req.maxAttempts ?? 120)))
            nodeCommands.append(command)
            writeNodeCommandsLocked()
            lock.unlock()
            publish(kind: .nodeCommand)
            return MeshResponse(ok: true, command: command)

        case "node-command-next":
            guard authorizeControl(req, trustedLocal: trustedLocal) else {
                return .fail("valid control credential required")
            }
            guard let nodeID = req.nodeID, !nodeID.isEmpty else { return .fail("node id required") }
            let now = Date().timeIntervalSince1970
            lock.lock()
            expireNodeCommandsLocked(now: now)
            guard let index = nodeCommands.indices.first(where: {
                nodeCommands[$0].nodeID == nodeID && !nodeCommands[$0].state.isTerminal
                    && nodeCommands[$0].nextAttemptAt <= now
            }) else {
                lock.unlock(); return MeshResponse(ok: true)
            }
            if nodeCommands[index].state == .queued {
                nodeCommands[index].state = .accepted
                nodeCommands[index].updatedAt = now
                writeNodeCommandsLocked()
            }
            let command = nodeCommands[index]
            lock.unlock()
            return MeshResponse(ok: true, command: command)

        case "node-command-update":
            guard authorizeControl(req, trustedLocal: trustedLocal) else {
                return .fail("valid control credential required")
            }
            guard let nodeID = req.nodeID, let commandID = req.commandID,
                  let rawState = req.state, let nextState = MeshNodeCommandState(rawValue: rawState) else {
                return .fail("node id, command id, and valid state required")
            }
            lock.lock()
            guard let index = nodeCommands.firstIndex(where: { $0.id == commandID && $0.nodeID == nodeID }) else {
                lock.unlock(); return .fail("command not found for node")
            }
            guard validCommandTransition(from: nodeCommands[index].state, to: nextState) else {
                lock.unlock(); return .fail("invalid command state transition")
            }
            if nextState == .running && nodeCommands[index].state != .running {
                nodeCommands[index].attempts += 1
            } else if nextState == .accepted, req.retryAt != nil {
                nodeCommands[index].attempts += 1
            } else if nextState.isTerminal && nodeCommands[index].attempts == 0 {
                // Executors may reject a command before entering `running`
                // (invalid ownership, gone pane, malformed payload). It was
                // still a real delivery attempt and observability must not
                // report the misleading 0/N.
                nodeCommands[index].attempts = 1
            }
            nodeCommands[index].state = nextState
            nodeCommands[index].updatedAt = Date().timeIntervalSince1970
            nodeCommands[index].result = req.payload
            if let retryAt = req.retryAt {
                nodeCommands[index].nextAttemptAt = max(nodeCommands[index].updatedAt, retryAt)
            }
            if !nodeCommands[index].state.isTerminal,
               nodeCommands[index].attempts >= nodeCommands[index].maxAttempts {
                nodeCommands[index].state = .failed
                nodeCommands[index].result = req.payload ?? "retry attempts exhausted"
            }
            let command = nodeCommands[index]
            writeNodeCommandsLocked()
            lock.unlock()
            publish(kind: .nodeCommand)
            return MeshResponse(ok: true, command: command)

        case "node-command-list":
            guard authorizeControl(req, trustedLocal: trustedLocal) else {
                return .fail("valid control credential required")
            }
            lock.lock()
            expireNodeCommandsLocked()
            let values = nodeCommands.filter { req.nodeID == nil || $0.nodeID == req.nodeID }
                .sorted { $0.createdAt > $1.createdAt }
            lock.unlock()
            return MeshResponse(ok: true, commands: values)

        case "node-list":
            lock.lock(); pruneNodesLocked()
            let activeNodes = nodes.values.sorted { $0.host < $1.host }
            lock.unlock()
            return MeshResponse(ok: true, nodes: activeNodes)

        case "pairing-create":
            guard authorizeControl(req, trustedLocal: trustedLocal) else {
                return .fail("valid control credential required")
            }
            guard let endpoint = req.host,
                  let split = meshSplitHostPort(endpoint),
                  let port = UInt16(split.port) else {
                return .fail("valid Broker endpoint required")
            }
            let now = Date().timeIntervalSince1970
            let lifetime = min(600, max(60, Double(req.timeoutMs ?? 300_000) / 1_000))
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            lock.lock()
            pairingTokens = pairingTokens.filter { $0.value > now }
            pairingTokens[token] = now + lifetime
            let brokerID = brokerIDLocked()
            lock.unlock()
            let pairing = MeshPairingLink(host: split.host, port: port, brokerID: brokerID,
                                          token: token, expiresAt: now + lifetime)
            guard let link = pairing.url?.absoluteString else {
                return .fail("couldn't encode pairing link")
            }
            return MeshResponse(ok: true, payload: link, capabilities: ["pairing-v2"])

        case "pairing-redeem":
            guard let token = req.payload, !token.isEmpty,
                  let expectedBrokerID = req.memberID, !expectedBrokerID.isEmpty else {
                return .fail("pairing token and Broker identity required")
            }
            let now = Date().timeIntervalSince1970
            lock.lock()
            let brokerID = brokerIDLocked()
            guard expectedBrokerID == brokerID else {
                lock.unlock()
                return .fail("Broker identity mismatch")
            }
            let expiry = pairingTokens.removeValue(forKey: token)
            lock.unlock()
            guard let expiry, expiry > now else { return .fail("pairing code expired or already used") }
            let credential = MeshPairingCredential(brokerID: brokerID, controlToken: controlToken())
            guard let data = try? JSONEncoder().encode(credential),
                  let payload = String(data: data, encoding: .utf8) else {
                return .fail("couldn't encode pairing credential")
            }
            return MeshResponse(ok: true, payload: payload, capabilities: [
                "mesh-v2", "pairing-v2", "node-v2"
            ])

        case "registry-get":
            return registrySnapshot()

        case "registry-put":
            guard let payload = req.payload, let expected = req.expectedRevision else {
                return .fail("payload and expected revision required")
            }
            return replaceRegistry(payload: payload, expectedRevision: expected)

        case "create":
            guard let r = req.room else { return .fail("room required") }
            lock.lock(); if rooms[r] == nil { rooms[r] = Room() }; writeMailboxesLocked(); lock.unlock()
            publish(kind: .roster, room: r)
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
                                nodeID: req.nodeID,
                                host: req.host, tmuxPane: req.tmuxPane, tmuxSocket: req.tmuxSocket,
                                state: MeshSessionState.busy.rawValue, kind: req.kind,
                                tailscaleIP: req.tailscaleIP)
            syncUnreadLocked(memberID)
            lock.unlock()
            publish(kind: .roster, room: r)
            // Hand the joiner the recent conversation so it can catch up.
            return MeshResponse(ok: true, messages: recentTranscript(r, limit: req.limit ?? 30))

        case "history":
            guard let r = req.room else { return .fail("room required") }
            if let before = req.beforeID {
                return MeshResponse(ok: true, messages: transcriptPage(r, before: before,
                                                                       limit: req.limit ?? 30))
            }
            return MeshResponse(ok: true, messages: recentTranscript(r, limit: req.limit ?? 30))

        case "leave":
            guard let r = req.room, let n = req.nick else { return .fail("room and nick required") }
            lock.lock()
            if let expected = req.memberID, rooms[r]?.members[n] != expected {
                lock.unlock(); return .fail("member identity changed; refresh and try again")
            }
            if let memberID = rooms[r]?.members.removeValue(forKey: n) {
                rooms[r]?.mailboxes[memberID] = nil    // leaving abandons that room's unread
                syncUnreadLocked(memberID)
                refreshPresenceRoomsLocked(memberID)
                writePresenceLocked()
            }
            lock.unlock()
            publish(kind: .roster, room: r)
            return .okay()

        case "rename-member":
            guard let r = req.room, let old = req.nick,
                  let new = req.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !new.isEmpty else { return .fail("room, current nick, and new nick required") }
            lock.lock()
            guard let memberID = rooms[r]?.members[old] else {
                lock.unlock(); return .fail("member not found")
            }
            if let expected = req.memberID, expected != memberID {
                lock.unlock(); return .fail("member identity changed; refresh and try again")
            }
            if let occupied = rooms[r]?.members[new], occupied != memberID {
                lock.unlock(); return .fail("nick already exists in room")
            }
            if old != new {
                rooms[r]?.members.removeValue(forKey: old)
                rooms[r]?.members[new] = memberID
                refreshPresenceRoomsLocked(memberID)
                syncUnreadLocked(memberID)
                writePresenceLocked()
            }
            lock.unlock()
            publish(kind: .roster, room: r)
            return .okay()

        case "say":
            let identity = resolveMessageSender(request: req)
            guard let r = identity.room, let n = identity.nick else {
                return .fail(identity.error ?? "member identity required")
            }
            let t = req.text ?? ""
            let attachments = req.attachments ?? []
            guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else {
                return .fail("text or attachment required")
            }
            for attachment in attachments {
                guard storedAttachment(id: attachment.id) == attachment else {
                    return .fail("attachment is missing or metadata does not match: \(attachment.id)")
                }
            }
            let reply: MeshReply?
            if let replyToID = req.replyToID {
                guard let resolved = replyReference(room: r, messageID: replyToID) else {
                    return .fail("quoted message not found in room")
                }
                reply = resolved
            } else {
                reply = nil
            }
            let delivery = deliver(room: r, from: n, text: t, to: req.to, replyTo: reply,
                                   attachments: attachments.isEmpty ? nil : attachments)
            publish(kind: .message, room: r, message: delivery.message)
            var unroutable: [String] = []
            if req.to?.isEmpty == false {
                for target in delivery.targets {
                    if enqueuePokeCommand(for: target,
                                          idempotencyKey: "message:\(delivery.message.id ?? "unknown")",
                                          requireUnread: true) == nil {
                        unroutable.append(target.nick)
                    }
                }
            }
            // Echo EVERY @-target's presence so the sender can act on delivery:
            // poke a stopped/idle tmux session, tell the human to nudge a
            // session we can't reach (no pane / blocked on a dialog) — and an
            // UNREGISTERED nick gets a bare placeholder, so mentioning someone
            // who never joined (or whose registration was lost) is never silent.
            lock.lock()
            let targetInfo = (req.to ?? []).map { nick in
                memberInfoLocked(room: r, nick: nick)
                    ?? MeshMemberInfo(id: "", nick: nick, nodeID: nil, project: nil, session: nil, host: nil,
                                      tmuxPane: nil, tmuxSocket: nil, state: nil, stateTs: nil, unread: nil,
                                      kind: nil, tailscaleIP: nil, rooms: [], lastSeen: 0)
            }
            lock.unlock()
            let note = unroutable.isEmpty ? nil
                : "Delivered, but automatic poke was not queued because the Host node is unavailable for "
                    + unroutable.map { "@\($0)" }.joined(separator: ", ") + "."
            return MeshResponse(ok: true, members: targetInfo.isEmpty ? nil : targetInfo, note: note)

        case "poke":
            guard let room = req.room, let nick = req.nick else {
                return .fail("room and nick required")
            }
            lock.lock()
            guard let member = memberInfoLocked(room: room, nick: nick) else {
                lock.unlock()
                return .fail("member not found in room")
            }
            guard member.nodeOnline == true else {
                lock.unlock()
                return .fail("the member's Host node is offline")
            }
            lock.unlock()
            guard enqueuePokeCommand(for: member, idempotencyKey: "manual:\(UUID().uuidString)",
                                     requireUnread: false) != nil else {
                return .fail("the member's Host node is offline")
            }
            return MeshResponse(ok: true, members: [member])

        case "mark":
            // Hook-reported session state (fire-and-forget from the reporter's
            // point of view). Resolve the agent by explicit nick, else by
            // (session, cwd) — same rules as peek. Unknown agent = silently ok:
            // a hook must never propagate an error back into a session.
            guard let s = req.state, MeshSessionState(rawValue: s) != nil else { return .fail("valid state required") }
            lock.lock()
            var memberID = resolveMemberIDLocked(request: req)
            // Self-heal: a `/clear`-minted session whose SessionStart rebind never
            // landed (e.g. the broker was down at that instant) resolves to
            // nothing, so its heartbeats would vanish into a dropped mark. If
            // this report proves the same physical seat, lazily reclaim the
            // orphaned predecessor now — the report carries (host, pane, socket).
            if memberID == nil, let newID = req.session, !newID.isEmpty,
               rebindLocked(to: newID, request: req, recencySeconds: Self.lazyRebindRecencySeconds) {
                memberID = newID
            }
            if let memberID, presence[memberID] != nil,
               Self.markMatchesSnapshot(presence[memberID]!, request: req) {
                let prior = presence[memberID]!.stateReason
                presence[memberID]!.state = s
                presence[memberID]!.stateTs = Date().timeIntervalSince1970
                // An open AskUserQuestion form reports blocked(form:…) from
                // PreToolUse, but the dialog then fires Notification{permission_prompt}
                // which would clobber the reason to "permission" and hide the
                // form from the node's Escape path. Keep the form reason sticky
                // while the session stays blocked; any non-blocked state clears it.
                if s == MeshSessionState.blocked.rawValue,
                   prior?.hasPrefix("form") == true,
                   req.stateReason?.hasPrefix("form") != true {
                    presence[memberID]!.stateReason = prior
                } else {
                    presence[memberID]!.stateReason = req.stateReason
                }
                writePresenceLocked()
            }
            lock.unlock()
            publish(kind: .roster)
            return .okay()

        case "rebind":
            // A new session on the same physical tmux seat reclaims a prior
            // session's rooms/mailbox/presence (see rebindLocked). Fired
            // proactively by the new session's SessionStart; the `mark` path is
            // a lazy backstop. Fail-soft: no eligible predecessor = silently ok
            // (a genuinely first-time session has nothing to reclaim).
            guard let newID = req.session, !newID.isEmpty else { return .fail("session required") }
            lock.lock()
            let moved = rebindLocked(to: newID, request: req, recencySeconds: Self.rebindRecencySeconds)
            lock.unlock()
            if moved { publish(kind: .roster) }
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
                presence[memberID]!.stateReason = req.stateReason
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
            writeMailboxesLocked()
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
            writeMailboxesLocked()
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

    /// Stable identity shown during pairing. It identifies the Broker data
    /// store, not the Mac or Linux machine currently serving it.
    private func brokerIDLocked() -> String {
        if let cachedBrokerID { return cachedBrokerID }
        if let stored = try? String(contentsOf: MeshPaths.brokerIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            cachedBrokerID = stored
            return stored
        }
        let created = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: MeshPaths.dataDirectory,
                                                  withIntermediateDirectories: true)
        try? Data((created + "\n").utf8).write(to: MeshPaths.brokerIDFile, options: .atomic)
        cachedBrokerID = created
        return created
    }

    /// Post a message (delivery model B, 2026-07-13):
    ///  • `@mention`  → DIRECTED: the named agents get it, and it pokes them
    ///    (a directed message carries a non-empty `to`).
    ///  • no mention  → BROADCAST: every OTHER room member gets it in their
    ///    mailbox (carries an empty `to`), so everyone receives it — but it does
    ///    NOT poke; each recipient sees it at its next turn boundary (Stop hook).
    /// The empty-vs-non-empty `to` on the stored `MeshMsg` is exactly what the
    /// poke path keys on, so no separate flag is needed.
    private func deliver(room r: String, from n: String, text t: String, to: [String]?,
                         replyTo: MeshReply?, attachments: [MeshAttachment]?)
        -> (message: MeshMsg, targets: [MeshMemberInfo]) {
        let msg = MeshMsg(id: UUID().uuidString, from: n, room: r, text: t,
                          ts: Date().timeIntervalSince1970, to: to ?? [],
                          replyTo: replyTo, attachments: attachments)
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
        let targets = targetIDs.compactMap { memberID -> MeshMemberInfo? in
            guard let alias = rooms[r]!.members.first(where: { $0.value == memberID })?.key else { return nil }
            return memberInfoLocked(room: r, nick: alias)
        }
        lock.unlock()
        appendTranscript(msg)
        return (msg, targets)
    }

    // MARK: event stream

    /// Publish into a bounded runtime replay buffer and wake every blocked
    /// subscriber. Durable state is intentionally elsewhere: reconnecting
    /// clients reload history/roster, while the cursor prevents duplicate UI
    /// refreshes and duplicate Pokes during an uninterrupted broker lifetime.
    private func publish(kind: MeshEvent.Kind, room: String? = nil,
                         message: MeshMsg? = nil, member: MeshMemberInfo? = nil) {
        eventCondition.lock()
        eventSequence &+= 1
        events.append(MeshEvent(sequence: eventSequence, kind: kind, room: room,
                                message: message, member: member))
        if events.count > maximumEvents { events.removeFirst(events.count - maximumEvents) }
        eventCondition.broadcast()
        eventCondition.unlock()
    }

    /// Long-poll one broker-owned event cursor. `cursor == nil` establishes a
    /// baseline without replaying old Pokes. Subsequent calls block until a new
    /// event arrives or the bounded timeout expires, then return immediately.
    private func waitForEvents(after cursor: UInt64?, timeoutMs: Int?) -> MeshResponse {
        eventCondition.lock()
        defer { eventCondition.unlock() }
        guard let cursor else {
            return MeshResponse(ok: true, events: [], cursor: eventSequence)
        }
        if cursor > eventSequence {
            return MeshResponse(ok: true, events: [], cursor: eventSequence)
        }
        let bounded = min(30_000, max(250, timeoutMs ?? 25_000))
        let deadline = Date(timeIntervalSinceNow: Double(bounded) / 1_000)
        while eventSequence <= cursor {
            if !eventCondition.wait(until: deadline) { break }
        }
        let batch = Array(events.lazy.filter { $0.sequence > cursor }.prefix(200))
        return MeshResponse(ok: true, events: batch,
                            cursor: batch.last?.sequence ?? eventSequence)
    }

    // MARK: authenticated durable Host commands

    private struct NodeCommandStore: Codable { var version: Int; var commands: [MeshNodeCommand] }
    private struct MailboxStore: Codable { var version: Int; var rooms: [String: Room] }

    private func loadPresenceLocked(resetStates: Bool) {
        guard let data = try? Data(contentsOf: MeshPaths.presenceFile),
              let previous = try? JSONDecoder().decode(MeshPresence.self, from: data) else { return }
        for (memberID, entry) in previous.members {
            var value = entry
            if resetStates { value.state = nil; value.stateTs = nil; value.stateReason = nil }
            presence[memberID] = value
            for (room, alias) in value.aliases {
                if rooms[room] == nil { rooms[room] = Room() }
                rooms[room]!.members[alias] = memberID
                if rooms[room]!.mailboxes[memberID] == nil { rooms[room]!.mailboxes[memberID] = [] }
            }
        }
    }

    private func loadMailboxesLocked() {
        guard let data = try? Data(contentsOf: MeshPaths.mailboxesFile),
              let store = try? JSONDecoder().decode(MailboxStore.self, from: data),
              store.version == 1 else { return }
        rooms = store.rooms
    }

    private func writeMailboxesLocked() {
        guard let data = try? JSONEncoder().encode(MailboxStore(version: 1, rooms: rooms)) else { return }
        try? FileManager.default.createDirectory(at: MeshPaths.dataDirectory, withIntermediateDirectories: true)
        try? data.write(to: MeshPaths.mailboxesFile, options: .atomic)
        #if !os(Windows)
        chmod(MeshPaths.mailboxesFile.path, 0o600)
        #endif
    }

    @discardableResult
    private func enqueuePokeCommand(for member: MeshMemberInfo, idempotencyKey: String,
                                    requireUnread: Bool, preferredNodeID: String? = nil) -> MeshNodeCommand? {
        lock.lock()
        pruneNodesLocked()
        let nodeID: String?
        if let preferredNodeID {
            nodeID = nodes[preferredNodeID]?.id
        } else if let owner = member.nodeID, !owner.isEmpty {
            // An explicit binding is authoritative. Falling back to a different
            // node merely because its display host happens to match would send
            // control input to the wrong machine after a restore or rename.
            nodeID = nodes[owner]?.id
        } else {
            nodeID = nodes.values.first(where: { node in
                if let memberIP = member.tailscaleIP, !memberIP.isEmpty,
                   let nodeIP = node.tailscaleIP, !nodeIP.isEmpty { return memberIP == nodeIP }
                return normalizedHost(member.host) == normalizedHost(node.host)
            })?.id
        }
        lock.unlock()
        guard let nodeID,
              let data = try? JSONEncoder().encode(MeshNodePokePayload(memberID: member.id,
                                                                       requireUnread: requireUnread)),
              let payload = String(data: data, encoding: .utf8) else { return nil }
        return process(MeshRequest(cmd: "node-command-enqueue", payload: payload,
                                   nodeID: nodeID, action: MeshNodeCommandAction.poke.rawValue,
                                   idempotencyKey: idempotencyKey + ":" + member.id,
                                   deadline: Date().timeIntervalSince1970 + 86_400,
                                   maxAttempts: 240), trustedLocal: true).command
    }

    /// A node may have been offline when messages were written. Its first
    /// heartbeat rebuilds missing durable poke commands from authoritative
    /// mailboxes, keyed by the newest directed message so repeats deduplicate.
    private func recoverUnreadPokes(nodeID: String, host: String, tailscaleIP: String?) {
        lock.lock()
        var recoveries: [(MeshMemberInfo, String)] = []
        for (memberID, entry) in presence {
            let owned: Bool
            if let owner = entry.nodeID, !owner.isEmpty {
                owned = owner == nodeID
            } else if let tailscaleIP, !tailscaleIP.isEmpty,
               let memberIP = entry.tailscaleIP, !memberIP.isEmpty {
                owned = tailscaleIP == memberIP
            } else {
                owned = normalizedHost(host) == normalizedHost(entry.host)
            }
            guard owned else { continue }
            let directed = rooms.values.flatMap { room -> [MeshMsg] in
                guard let alias = room.members.first(where: { $0.value == memberID })?.key else { return [] }
                return (room.mailboxes[memberID] ?? []).filter { $0.to.contains(alias) }
            }
            guard let newest = directed.max(by: { $0.ts < $1.ts }),
                  let room = entry.rooms.first,
                  let nick = entry.aliases[room],
                  let member = memberInfoLocked(room: room, nick: nick) else { continue }
            // Use the same key as initial directed delivery. Heartbeats are
            // frequent and recovery must converge on that command rather than
            // create a parallel poke for the same mailbox message.
            recoveries.append((member, "message:\(newest.id ?? "unknown")"))
        }
        lock.unlock()
        for (member, key) in recoveries {
            _ = enqueuePokeCommand(for: member, idempotencyKey: key, requireUnread: true,
                                   preferredNodeID: nodeID)
        }
    }

    private func controlToken() -> String {
        lock.lock(); defer { lock.unlock() }
        if let cachedControlToken { return cachedControlToken }
        if let raw = try? String(contentsOf: MeshPaths.brokerControlTokenFile, encoding: .utf8) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 32 {
                cachedControlToken = value
                MeshPaths.setControlTokenFile(value)
                return value
            }
        }
        let value = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        try? FileManager.default.createDirectory(at: MeshPaths.dataDirectory, withIntermediateDirectories: true)
        try? (value + "\n").write(to: MeshPaths.brokerControlTokenFile,
                                    atomically: true, encoding: .utf8)
        #if !os(Windows)
        chmod(MeshPaths.brokerControlTokenFile.path, 0o600)
        #endif
        cachedControlToken = value
        MeshPaths.setControlTokenFile(value)
        return value
    }

    private func authorizeControl(_ request: MeshRequest, trustedLocal: Bool) -> Bool {
        if trustedLocal { return true }
        guard let supplied = request.authToken else { return false }
        let expected = controlToken()
        guard supplied.utf8.count == expected.utf8.count else { return false }
        return zip(supplied.utf8, expected.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func loadNodeCommandsLocked() {
        guard let data = try? Data(contentsOf: MeshPaths.nodeCommandsFile),
              let store = try? JSONDecoder().decode(NodeCommandStore.self, from: data) else { return }
        nodeCommands = store.commands
        expireNodeCommandsLocked()
    }

    private func writeNodeCommandsLocked() {
        let retained = nodeCommands.filter {
            !$0.state.isTerminal || Date().timeIntervalSince1970 - $0.updatedAt < 7 * 86_400
        }
        nodeCommands = retained
        guard let data = try? JSONEncoder().encode(NodeCommandStore(version: 1, commands: retained)) else { return }
        try? FileManager.default.createDirectory(at: MeshPaths.dataDirectory, withIntermediateDirectories: true)
        try? data.write(to: MeshPaths.nodeCommandsFile, options: .atomic)
        #if !os(Windows)
        chmod(MeshPaths.nodeCommandsFile.path, 0o600)
        #endif
    }

    private func expireNodeCommandsLocked(now: Double = Date().timeIntervalSince1970) {
        var changed = false
        for index in nodeCommands.indices where !nodeCommands[index].state.isTerminal
            && nodeCommands[index].deadline <= now {
            nodeCommands[index].state = .expired
            nodeCommands[index].updatedAt = now
            nodeCommands[index].result = "deadline exceeded"
            changed = true
        }
        if changed { writeNodeCommandsLocked() }
    }

    private func validCommandTransition(from: MeshNodeCommandState,
                                        to: MeshNodeCommandState) -> Bool {
        if from == to { return true } // idempotent ACK after a lost response
        return switch (from, to) {
        case (.queued, .accepted), (.queued, .running), (.queued, .failed), (.queued, .canceled),
             (.accepted, .running), (.accepted, .succeeded), (.accepted, .failed), (.accepted, .canceled),
             (.running, .succeeded), (.running, .failed), (.running, .canceled): true
        default: false
        }
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
        writeMailboxesLocked()
        try? FileManager.default.createDirectory(at: MeshPaths.unreadDir, withIntermediateDirectories: true)
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
                                     nodeID: String? = nil,
                                     host: String? = nil, tmuxPane: String? = nil, tmuxSocket: String? = nil,
                                     state: String? = nil,
                                     kind: String? = nil, tailscaleIP: String? = nil) {
        let aliases = Dictionary(uniqueKeysWithValues: rooms.compactMap { room, value in
            value.members.first(where: { $0.value == memberID }).map { (room, $0.key) }
        })
        if presence[memberID] == nil && aliases.isEmpty { return }
        var e = presence[memberID] ?? MeshPresenceEntry(nodeID: nil, project: nil, session: nil, host: nil, tmuxPane: nil,
                                                        tmuxSocket: nil,
                                                        state: nil, stateTs: nil, kind: nil, tailscaleIP: nil,
                                                        aliases: [:], rooms: [], lastSeen: 0, online: true)
        if let owner = nodeID, !owner.isEmpty { e.nodeID = owner }
        if let p = project, !p.isEmpty { e.project = p }
        if let s = session, !s.isEmpty { e.session = s }
        if let h = host, !h.isEmpty { e.host = h }
        if let k = kind, !k.isEmpty { e.kind = k }
        if let ip = tailscaleIP, !ip.isEmpty { e.tailscaleIP = ip }
        // A re-join OUTSIDE tmux must clear a stale pane from an earlier
        // tmux-wrapped join, so join always overwrites (nil included) when it
        // carries identity; plain touches (say/recv) leave it alone.
        if session != nil || project != nil {
            e.tmuxPane = tmuxPane
            e.tmuxSocket = tmuxSocket
        }
        if let st = state {
            e.state = st
            e.stateTs = Date().timeIntervalSince1970
            e.stateReason = nil
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
        return MeshMemberInfo(id: memberID, nick: nick, nodeID: e.nodeID,
                              project: e.project, session: e.session, host: e.host,
                              tmuxPane: e.tmuxPane, tmuxSocket: e.tmuxSocket,
                              state: e.state, stateTs: e.stateTs, stateReason: e.stateReason,
                              unread: unread, kind: e.kind, tailscaleIP: e.tailscaleIP,
                              rooms: [room], lastSeen: e.lastSeen,
                              nodeOnline: nodeIsOnlineLocked(nodeID: e.nodeID, host: e.host,
                                                             tailscaleIP: e.tailscaleIP))
    }

    private func pruneNodesLocked(now: Double = Date().timeIntervalSince1970) {
        nodes = nodes.filter { now - $0.value.lastSeen < 70 }
    }

    private func nodeIsOnlineLocked(nodeID: String?, host: String?, tailscaleIP: String?) -> Bool {
        pruneNodesLocked()
        if let nodeID, !nodeID.isEmpty { return nodes[nodeID] != nil }
        return nodes.values.contains { node in
            if let tailscaleIP, !tailscaleIP.isEmpty,
               let nodeIP = node.tailscaleIP, !nodeIP.isEmpty { return tailscaleIP == nodeIP }
            return normalizedHost(host) == normalizedHost(node.host)
        }
    }

    private func normalizedHost(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    // MARK: - Registry (the hub is the source of truth; clients read over mesh)

    /// All registered projects as JSON matching the mobile parser
    /// (`{"projects":[{name, localPath, githubRemote, tags}]}`).
    private func registryProjectsJSON() -> String {
        Self.jsonString(["projects": registryProjects()]) ?? #"{"projects":[]}"#
    }

    /// Every open issue across all projects
    /// (`{"issues":[{project, number, title, status, priority, labels}]}`).
    private func registryIssuesJSON() -> String {
        var out: [[String: Any]] = []
        for project in registryProjects() {
            guard let name = project["name"] as? String,
                  let issues = project["issues"] as? [[String: Any]] else { continue }
            for issue in issues {
                let status = issue["status"] as? String ?? "todo"
                guard status != "done", status != "canceled" else { continue }
                out.append(["project": name,
                            "number": issue["number"] as? Int ?? 0,
                            "title": issue["title"] as? String ?? "Untitled",
                            "status": status,
                            "priority": issue["priority"] as? String ?? "none",
                            "labels": issue["labels"] as? [String] ?? [],
                            "body": issue["body"] as? String ?? "",
                            "activeSession": issue["activeSession"] as? String ?? ""])
            }
        }
        return Self.jsonString(["issues": out]) ?? #"{"issues":[]}"#
    }

    private static let maximumRegistryBytes = 10 * 1024 * 1024

    /// The Broker is the sole authority for portable project state. Reads carry
    /// a content revision and writes are compare-and-swap, so two clients can
    /// never silently overwrite one another.
    private func registrySnapshot() -> MeshResponse {
        lock.lock(); defer { lock.unlock() }
        let data = registryDataLocked()
        guard let payload = String(data: data, encoding: .utf8) else {
            return .fail("registry is not UTF-8 JSON")
        }
        return MeshResponse(ok: true, payload: payload, revision: Self.registryRevision(data))
    }

    private func replaceRegistry(payload: String, expectedRevision: String) -> MeshResponse {
        guard let proposed = payload.data(using: .utf8),
              !proposed.isEmpty, proposed.count <= Self.maximumRegistryBytes,
              Self.validRegistry(proposed) else {
            return .fail("registry must be a JSON object containing a projects array (maximum 10 MiB)")
        }
        lock.lock(); defer { lock.unlock() }
        let current = registryDataLocked()
        let currentRevision = Self.registryRevision(current)
        guard expectedRevision == currentRevision else {
            return MeshResponse(ok: false, error: "registry conflict", revision: currentRevision)
        }
        let proposedRevision = Self.registryRevision(proposed)
        if proposedRevision == currentRevision {
            return MeshResponse(ok: true, revision: currentRevision)
        }
        do {
            try FileManager.default.createDirectory(at: MeshPaths.dataDirectory,
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: MeshPaths.registryBackupDir,
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: MeshPaths.registryFile.path) {
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let backup = MeshPaths.registryBackupDir
                    .appendingPathComponent("\(stamp)-\(currentRevision.prefix(12)).json")
                try current.write(to: backup, options: .atomic)
                pruneRegistryBackupsLocked(keeping: 200)
            }
            try proposed.write(to: MeshPaths.registryFile, options: .atomic)
            return MeshResponse(ok: true, revision: proposedRevision)
        } catch {
            return .fail("cannot persist registry: \(error.localizedDescription)")
        }
    }

    private func registryDataLocked() -> Data {
        if let data = try? Data(contentsOf: MeshPaths.registryFile) { return data }
        return Data(#"{"groups":[],"projects":[],"trash":[]}"#.utf8)
    }

    private func pruneRegistryBackupsLocked(keeping limit: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: MeshPaths.registryBackupDir,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let ordered = files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for file in ordered.dropFirst(limit) { try? FileManager.default.removeItem(at: file) }
    }

    private static func registryRevision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validRegistry(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["projects"] is [Any] else { return false }
        return true
    }

    /// The headless broker treats the registry as opaque JSON. This keeps the
    /// Linux service independent from AppKit/project-launch code while still
    /// serving the same project and issue read models to mobile clients.
    private func registryProjects() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: MeshPaths.registryFile),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let root = object as? [String: Any], let projects = root["projects"] as? [[String: Any]] {
            return projects
        }
        return object as? [[String: Any]] ?? []
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

    /// Resolve an agent's display identity from broker-owned membership state.
    /// Agent-provided nicknames are deliberately ignored: a member/session ID
    /// selects the room-scoped alias that was registered by `join`. GUI/mobile
    /// requests remain the explicit `human` actor under the Tailscale trust boundary.
    private func resolveMessageSender(request req: MeshRequest)
        -> (room: String?, nick: String?, error: String?) {
        guard let memberID = req.memberID, !memberID.isEmpty else {
            guard req.nick == "human", let room = req.room, !room.isEmpty else {
                return (nil, nil, "member identity required; run this command from a joined agent session")
            }
            return (room, "human", nil)
        }

        lock.lock()
        defer { lock.unlock() }
        guard let entry = presence[memberID] else {
            return (nil, nil, "member session is not joined; run pharos mesh join first")
        }
        let memberships = entry.aliases.filter { room, alias in
            rooms[room]?.members[alias] == memberID
        }
        if let requestedRoom = req.room, !requestedRoom.isEmpty {
            guard let alias = memberships[requestedRoom] else {
                return (nil, nil, "member session has not joined room \(requestedRoom)")
            }
            return (requestedRoom, alias, nil)
        }
        guard !memberships.isEmpty else {
            return (nil, nil, "member session has not joined a room")
        }
        guard memberships.count == 1, let only = memberships.first else {
            let names = memberships.keys.sorted().joined(separator: ", ")
            return (nil, nil, "member session belongs to multiple rooms (\(names)); specify --room")
        }
        return (only.key, only.value, nil)
    }

    /// Recompute a nick's room list without bumping lastSeen (room deleted/renamed).
    /// A same-seat predecessor whose `lastSeen` is older than this is treated as
    /// a stale mapping, not a `/clear` reconnect, and is NOT rebound. A real
    /// `/clear` re-mints the session and reconnects within ~0.2s (and the
    /// predecessor's SessionEnd `mark` refreshes its `lastSeen` right before the
    /// successor arrives), so a generous window never false-rejects one; it only
    /// guards the rare case where a tmux server restart recycled a `%N` pane id
    /// onto an unrelated agent that happens to share the same cwd.
    private static let rebindRecencySeconds: Double = 1800

    /// Tighter recency for the source-blind lazy `mark` path (P1 gates on
    /// SessionStart.source; the lazy path can't see it). A real reconnect whose
    /// proactive rebind was lost re-marks within seconds; a genuinely new agent
    /// reusing a seat for a different task is typically minutes later. Paired
    /// with the `state != .gone` gate below, not a substitute for it.
    private static let lazyRebindRecencySeconds: Double = 90

    /// Reclaim an orphaned prior session's rooms, mailbox and presence onto a
    /// `newID` that occupies the same physical tmux seat. This is what rescues a
    /// member after `/clear` (or an in-place restart): the agent mints a fresh
    /// session id while its pane/socket/host are unchanged, so the roster would
    /// otherwise stay pinned to the dead session id and the live one go invisible.
    ///
    /// The predecessor is matched by physical seat `(host, tmuxSocket, tmuxPane)`
    /// — NEVER by cwd alone, since co-located agents share a directory. cwd is a
    /// SECONDARY confirmation; `recencySeconds` rejects a recycled pane id; and a
    /// predecessor already marked `.gone` is a genuinely-exited agent whose seat
    /// a fresh one must not inherit (the gate is `!= .gone`, NOT `== .stopped`:
    /// if the broker was also down at the predecessor's SessionEnd — the very
    /// case the lazy path exists for — its state never advanced past busy/idle,
    /// and `== .stopped` would wrongly block the reclaim we most need). The
    /// transfer MERGES (never overwrites): a `newID` that already joined rooms of
    /// its own keeps them. Returns whether a rebind happened. Call with `lock` held.
    private func rebindLocked(to newID: String, request req: MeshRequest,
                             recencySeconds: Double) -> Bool {
        guard !newID.isEmpty, let pane = req.tmuxPane, !pane.isEmpty else { return false }
        let now = Date().timeIntervalSince1970
        // The most-recently-seen eligible predecessor on this exact seat.
        let predecessor = presence
            .filter { id, e in
                id != newID
                    && e.tmuxPane == pane
                    && e.tmuxSocket == req.tmuxSocket
                    && (req.host == nil || e.host == nil || e.host == req.host)
                    // cwd: reject a different project reusing the seat, but never
                    // key on cwd alone (co-located agents share a directory).
                    && (req.project == nil || e.project == nil || e.project == req.project)
                    // A genuinely-exited agent is `.gone`; never inherit its seat.
                    // Deliberate corner (not a bug): a real exit
                    // (prompt_input_exit/logout → .gone) THEN a `resume` on the
                    // same pane is refused too — it did fully leave, so a
                    // conservative refuse beats mis-moving rooms, and the human
                    // re-joins explicitly. Normal resume is unaffected: its
                    // predecessor ended reason=resume → .stopped, so the gate passes.
                    && e.state != MeshSessionState.gone.rawValue
                    && now - e.lastSeen <= recencySeconds
            }
            .max { $0.value.lastSeen < $1.value.lastSeen }
        guard let (oldID, old) = predecessor else { return false }

        // Move every room membership + mailbox old → new. MERGE, don't clobber:
        // if the successor already sits in a room under its OWN nick (lazy path,
        // where it self-joined before rebinding), don't add a second nick for the
        // same member — that would double it in `who`; just fold the mailbox in
        // and drop the predecessor's now-redundant nick so its ghost can clear.
        for name in rooms.keys {
            guard let nick = rooms[name]!.members.first(where: { $0.value == oldID })?.key
            else { continue }
            let mail = rooms[name]!.mailboxes.removeValue(forKey: oldID) ?? []
            if rooms[name]!.members.values.contains(newID) {
                rooms[name]!.members.removeValue(forKey: nick)
            } else {
                rooms[name]!.members[nick] = newID
            }
            if !mail.isEmpty { rooms[name]!.mailboxes[newID, default: []].append(contentsOf: mail) }
        }
        // Carry the predecessor's durable identity onto the new entry (keeping
        // anything the new session already set for itself), reset to busy, and
        // let refreshPresenceRoomsLocked rebuild aliases/rooms from the map.
        var e = presence[newID] ?? old
        if e.kind == nil { e.kind = old.kind }
        if e.nodeID == nil { e.nodeID = req.nodeID ?? old.nodeID }
        if e.host == nil { e.host = req.host ?? old.host }
        if e.tailscaleIP == nil { e.tailscaleIP = old.tailscaleIP }
        e.session = newID
        e.tmuxPane = pane
        e.tmuxSocket = req.tmuxSocket ?? old.tmuxSocket
        if let cwd = req.project ?? old.project { e.project = cwd }
        e.state = MeshSessionState.busy.rawValue
        e.stateTs = now
        e.stateReason = nil
        e.online = true
        e.lastSeen = now
        presence[newID] = e
        refreshPresenceRoomsLocked(newID)   // rebuild new aliases/rooms from map
        refreshPresenceRoomsLocked(oldID)   // drops the old ghost once it's empty
        syncUnreadLocked(newID)
        syncUnreadLocked(oldID)
        writeMailboxesLocked()
        writePresenceLocked()
        return true
    }

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
        try? FileManager.default.createDirectory(at: MeshPaths.stateDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(snap) { try? d.write(to: MeshPaths.presenceFile, options: .atomic) }
    }

    private static let maximumAttachmentBytes = DistributedMeshProtocol.maximumBlobBytes

    private func handleAttachmentUpload(_ fd: Int32, request: MeshRequest) {
        guard let attachment = request.attachment,
              UUID(uuidString: attachment.id) != nil,
              attachment.byteSize > 0,
              attachment.byteSize <= Self.maximumAttachmentBytes,
              attachment.sha256.count == 64,
              !attachment.name.isEmpty,
              URL(fileURLWithPath: attachment.name).lastPathComponent == attachment.name else {
            writeResponse(.fail("invalid attachment metadata"), to: fd)
            return
        }
        guard let bytes = meshReadExactly(fd, count: attachment.byteSize) else {
            writeResponse(.fail("attachment upload ended early"), to: fd)
            return
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == attachment.sha256.lowercased() else {
            writeResponse(.fail("attachment checksum mismatch"), to: fd)
            return
        }

        let directory = MeshPaths.attachmentDirectory(attachment.id)
        let temporary = directory.appendingPathComponent("data.upload-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: temporary, options: .atomic)
            let destination = MeshPaths.attachmentData(attachment.id)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            let metadata = try JSONEncoder().encode(attachment)
            try metadata.write(to: MeshPaths.attachmentMetadata(attachment.id), options: .atomic)
            writeResponse(MeshResponse(ok: true, attachment: attachment), to: fd)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            writeResponse(.fail("cannot store attachment: \(error.localizedDescription)"), to: fd)
        }
    }

    private func handleAttachmentDownload(_ fd: Int32, request: MeshRequest) {
        guard let id = request.attachmentID,
              let attachment = storedAttachment(id: id),
              let data = try? Data(contentsOf: MeshPaths.attachmentData(id)),
              data.count == attachment.byteSize else {
            writeResponse(.fail("attachment not found"), to: fd)
            return
        }
        writeResponse(MeshResponse(ok: true, attachment: attachment), to: fd)
        meshWriteRaw(fd, data)
    }

    private func writeResponse(_ response: MeshResponse, to fd: Int32) {
        if let data = try? JSONEncoder().encode(response) { meshWriteAll(fd, data) }
    }

    private func storedAttachment(id: String) -> MeshAttachment? {
        guard let data = try? Data(contentsOf: MeshPaths.attachmentMetadata(id)),
              let attachment = try? JSONDecoder().decode(MeshAttachment.self, from: data),
              FileManager.default.fileExists(atPath: MeshPaths.attachmentData(id).path) else { return nil }
        return attachment
    }

    private func replyReference(room: String, messageID: String) -> MeshReply? {
        guard let original = transcript(room).first(where: { $0.stableID == messageID }) else { return nil }
        let compact = original.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = compact.count > 240 ? String(compact.prefix(237)) + "…" : compact
        return MeshReply(messageID: original.stableID, from: original.from,
                         preview: preview.isEmpty ? "Attachment" : preview, ts: original.ts)
    }

    private func transcript(_ room: String) -> [MeshMsg] {
        guard let data = try? String(contentsOf: MeshPaths.transcript(room), encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return data.split(separator: "\n").compactMap { try? dec.decode(MeshMsg.self, from: Data($0.utf8)) }
    }

    /// The last `limit` messages of a room, from its transcript (the durable log
    /// of everything said, mention or not).
    private func recentTranscript(_ room: String, limit: Int) -> [MeshMsg] {
        Array(transcript(room).suffix(max(0, limit)))
    }

    /// The `limit` messages immediately preceding the message with `before`'s
    /// id. An unknown anchor returns empty — the client treats that as "no
    /// further history" instead of silently restarting from the tail.
    private func transcriptPage(_ room: String, before: String, limit: Int) -> [MeshMsg] {
        let all = transcript(room)
        guard let index = all.lastIndex(where: { $0.id == before }) else { return [] }
        let lower = max(0, index - max(0, limit))
        return Array(all[lower..<index])
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
