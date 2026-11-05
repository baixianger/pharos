import Foundation

public struct CodexWatchRequest: Codable, Equatable, Sendable {
    public var id: String
    public var method: String
    public var summary: String

    public init(id: String, method: String, summary: String) {
        self.id = id
        self.method = method
        self.summary = summary
    }
}

public struct CodexWatchThread: Codable, Equatable, Sendable {
    /// "idle" | "active" | "notLoaded" | "systemError"
    public var status: String
    public var flags: [String]
    public var at: Date
    public var pending: [CodexWatchRequest]

    public init(status: String, flags: [String] = [], at: Date, pending: [CodexWatchRequest] = []) {
        self.status = status
        self.flags = flags
        self.at = at
        self.pending = pending
    }
}

public struct CodexWatchState: Codable, Equatable, Sendable {
    public var updatedAt: Date
    public var connected: Bool
    public var threads: [String: CodexWatchThread]

    public init(updatedAt: Date, connected: Bool, threads: [String: CodexWatchThread] = [:]) {
        self.updatedAt = updatedAt
        self.connected = connected
        self.threads = threads
    }
}

public enum CodexWatchFile {
    public static func defaultURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let explicit = env["PHAROS_CODEX_WATCH_FILE"], !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        if let meshDir = env["PHAROS_MESH_DIR"], !meshDir.isEmpty {
            return URL(fileURLWithPath: (meshDir as NSString).expandingTildeInPath)
                .appendingPathComponent("codex-watch.json")
        }
        let home = ("~/.local/state/pharos" as NSString).expandingTildeInPath
        return URL(fileURLWithPath: home).appendingPathComponent("codex-watch.json")
    }

    public static func save(_ state: CodexWatchState, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(state)
        let tmp = parent.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp)
        #if canImport(Darwin)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        #endif
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    public static func read(_ url: URL, now: Date = Date(), maxAge: TimeInterval = 45) -> CodexWatchState? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let state = try? decoder.decode(CodexWatchState.self, from: data) else { return nil }
        guard state.connected else { return nil }
        if now.timeIntervalSince(state.updatedAt) > maxAge { return nil }
        return state
    }
}

public final class CodexDaemonWatcher: @unchecked Sendable {
    public typealias Clock = @Sendable () -> Date
    public typealias Sleep = @Sendable (TimeInterval) -> Void
    public typealias ClientFactory = @Sendable (String) -> CodexDaemonClient

    private let socketPath: String
    private let outputURL: URL
    private let clock: Clock
    private let sleepFn: Sleep
    private let clientFactory: ClientFactory

    private let lock = NSLock()
    private var thread: Thread?
    private var isStopped = false
    private var activeClient: CodexDaemonClient?

    public init(
        socketPath: String = CodexDaemonClient.socketPath(),
        outputURL: URL = CodexWatchFile.defaultURL(),
        clock: @escaping Clock = { Date() },
        sleep: @escaping Sleep = { Thread.sleep(forTimeInterval: $0) },
        clientFactory: @escaping ClientFactory = { CodexDaemonClient(socketPath: $0) }
    ) {
        self.socketPath = socketPath
        self.outputURL = outputURL
        self.clock = clock
        self.sleepFn = sleep
        self.clientFactory = clientFactory
    }

    deinit {
        stop()
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard thread == nil else { return }
        isStopped = false
        let t = Thread { [weak self] in
            self?.runLoop()
        }
        t.name = "pharos.codex-daemon-watcher"
        thread = t
        t.start()
    }

    public func stop() {
        lock.lock()
        isStopped = true
        let client = activeClient
        activeClient = nil
        lock.unlock()

        client?.close()
    }

    private func checkStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    private func runLoop() {
        while !checkStopped() {
            guard FileManager.default.fileExists(atPath: socketPath) else {
                try? CodexWatchFile.save(CodexWatchState(updatedAt: clock(), connected: false, threads: [:]), to: outputURL)
                sleepFn(10)
                continue
            }

            let client = clientFactory(socketPath)
            lock.lock()
            if isStopped {
                lock.unlock()
                return
            }
            activeClient = client
            lock.unlock()

            do {
                try client.connect()
                var threads: [String: CodexWatchThread] = [:]
                let loaded = try client.loadedThreads()
                for tid in loaded {
                    if let info = try? client.readThread(tid) {
                        let statusStr: String
                        let flags: [String]
                        switch info.status {
                        case .idle:
                            statusStr = "idle"
                            flags = []
                        case .notLoaded:
                            statusStr = "notLoaded"
                            flags = []
                        case .systemError:
                            statusStr = "systemError"
                            flags = []
                        case .active(let f):
                            statusStr = "active"
                            flags = f
                        }
                        if statusStr != "notLoaded" {
                            threads[tid] = CodexWatchThread(status: statusStr, flags: flags, at: clock(), pending: [])
                        }
                    }
                }

                var lastWritten = clock()
                try CodexWatchFile.save(CodexWatchState(updatedAt: lastWritten, connected: true, threads: threads), to: outputURL)

                while !checkStopped() {
                    let events = try client.waitForEvents(timeout: 5)
                    var changed = false

                    for event in events {
                        let method = event["method"] as? String
                        let reqIdVal = event["id"]
                        let params = event["params"] as? [String: Any]

                        // Server request: has id and method
                        if let method, let reqIdVal {
                            let reqId = String(describing: reqIdVal)
                            let tid = params?["threadId"] as? String
                            let summary = (params?["command"] as? String) ?? (params?["reason"] as? String) ?? method
                            if let tid {
                                var thread = threads[tid] ?? CodexWatchThread(status: "active", flags: [], at: clock(), pending: [])
                                if !thread.pending.contains(where: { $0.id == reqId }) {
                                    thread.pending.append(CodexWatchRequest(id: reqId, method: method, summary: summary))
                                    thread.at = clock()
                                    threads[tid] = thread
                                    changed = true
                                }
                            }
                            continue
                        }

                        // Notifications: method without id
                        guard let method else { continue }
                        switch method {
                        case "thread/status/changed":
                            if let tid = params?["threadId"] as? String {
                                let statusObj = params?["status"] as? [String: Any]
                                let type = statusObj?["type"] as? String ?? "idle"
                                let flags = statusObj?["activeFlags"] as? [String] ?? []
                                if type == "notLoaded" {
                                    if threads.removeValue(forKey: tid) != nil {
                                        changed = true
                                    }
                                } else {
                                    var thread = threads[tid] ?? CodexWatchThread(status: type, flags: flags, at: clock(), pending: [])
                                    thread.status = type
                                    thread.flags = flags
                                    thread.at = clock()
                                    threads[tid] = thread
                                    changed = true
                                }
                            }
                        case "serverRequest/resolved":
                            let resolvedIdRaw = (params?["requestId"] as? String) ?? (params?["id"] as? String) ?? (params?["requestId"] as? Int).map(String.init) ?? (params?["id"] as? Int).map(String.init)
                            if let resolvedId = resolvedIdRaw {
                                for (tid, var thread) in threads {
                                    let prevCount = thread.pending.count
                                    thread.pending.removeAll { $0.id == resolvedId }
                                    if thread.pending.count != prevCount {
                                        thread.at = clock()
                                        threads[tid] = thread
                                        changed = true
                                    }
                                }
                            }
                        case "thread/closed":
                            if let tid = params?["threadId"] as? String {
                                if threads.removeValue(forKey: tid) != nil {
                                    changed = true
                                }
                            }
                        default:
                            break
                        }
                    }

                    let now = clock()
                    if changed || now.timeIntervalSince(lastWritten) >= 15 {
                        try CodexWatchFile.save(CodexWatchState(updatedAt: now, connected: true, threads: threads), to: outputURL)
                        lastWritten = now
                    }
                }
            } catch {
                client.close()
                lock.lock()
                activeClient = nil
                lock.unlock()
                try? CodexWatchFile.save(CodexWatchState(updatedAt: clock(), connected: false, threads: [:]), to: outputURL)
                if !checkStopped() {
                    sleepFn(5)
                }
            }
        }
    }
}
