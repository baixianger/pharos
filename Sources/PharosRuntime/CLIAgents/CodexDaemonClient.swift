import Foundation

public enum CodexThreadStatus: Equatable, Sendable {
    case idle
    case notLoaded
    case systemError
    case active(flags: [String])

    public var needsHuman: Bool {
        if case .active(let flags) = self {
            return flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput")
        }
        return false
    }

    public var busy: Bool {
        if case .active = self {
            return true
        }
        return false
    }
}

public struct CodexThreadInfo: Equatable, Sendable {
    public var id: String
    public var cwd: String?
    public var path: String?
    public var originator: String?
    public var status: CodexThreadStatus

    public init(
        id: String,
        cwd: String? = nil,
        path: String? = nil,
        originator: String? = nil,
        status: CodexThreadStatus
    ) {
        self.id = id
        self.cwd = cwd
        self.path = path
        self.originator = originator
        self.status = status
    }
}

public struct CodexTurn: Equatable, Sendable {
    public var id: String
    public var status: String
    public var startedAt: Date?
    public var completedAt: Date?
    public var clientIDs: [String]
    public var finalAnswer: String?
    public var errorMessage: String?
    public var errorInfo: String?

    public init(
        id: String,
        status: String,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        clientIDs: [String] = [],
        finalAnswer: String? = nil,
        errorMessage: String? = nil,
        errorInfo: String? = nil
    ) {
        self.id = id
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.clientIDs = clientIDs
        self.finalAnswer = finalAnswer
        self.errorMessage = errorMessage
        self.errorInfo = errorInfo
    }
}

public struct CodexServerRequest: Equatable, Sendable {
    public var id: String
    public var method: String
    public var threadId: String?
    public var summary: String

    public init(id: String, method: String, threadId: String? = nil, summary: String) {
        self.id = id
        self.method = method
        self.threadId = threadId
        self.summary = summary
    }
}

public enum CodexDaemonError: Error, Equatable {
    case unavailable(String)
    case rpc(code: Int, message: String)
    case protocolError(String)
    case timeout
}

public final class CodexDaemonClient: @unchecked Sendable {
    private let lock = NSLock()
    private let socketPath: String
    private let timeout: TimeInterval
    private var conn: WebSocketUDSConnection?
    private var nextRequestId: Int = 1
    private var _observedServerRequests: [CodexServerRequest] = []
    private var _notifications: [[String: Any]] = []

    public var observedServerRequests: [CodexServerRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _observedServerRequests
    }

    public var notifications: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return _notifications
    }

    public static func socketPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let home: String
        if let codexHome = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !codexHome.isEmpty {
            home = codexHome
        } else {
            home = ("~/.codex" as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("app-server-control")
            .appendingPathComponent("app-server-control.sock")
            .path
    }

    public init(socketPath: String, timeout: TimeInterval = 8) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    deinit {
        close()
    }

    public func connect() throws {
        lock.lock()
        defer { lock.unlock() }
        try connectLocked()
    }

    private func connectLocked() throws {
        if conn != nil { return }
        let connection = try WebSocketUDSConnection(socketPath: socketPath, timeout: timeout)
        self.conn = connection

        // Handshake: initialize
        let initRequest: [String: Any] = [
            "id": 0,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "pharos", "version": "1"],
                "capabilities": ["experimentalApi": true]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: initRequest)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw CodexDaemonError.protocolError("failed to encode initialize JSON")
        }
        try connection.sendText(jsonString)

        let deadline = Date().addingTimeInterval(timeout)
        _ = try waitForResponseLocked(expectedId: 0, deadline: deadline)

        // Notification: initialized
        let notify = "{\"method\":\"initialized\"}"
        try connection.sendText(notify)
    }

    public func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        try connectLocked()
        guard let connection = self.conn else {
            throw CodexDaemonError.unavailable("connection not available")
        }

        let reqId = nextRequestId
        nextRequestId += 1

        let payload: [String: Any] = [
            "id": reqId,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexDaemonError.protocolError("failed to encode request JSON")
        }
        try connection.sendText(text)

        let deadline = Date().addingTimeInterval(timeout)
        return try waitForResponseLocked(expectedId: reqId, deadline: deadline)
    }

    private func waitForResponseLocked(expectedId: Int, deadline: Date) throws -> [String: Any] {
        guard let connection = self.conn else {
            throw CodexDaemonError.unavailable("connection not available")
        }

        while Date() < deadline {
            guard let text = try connection.receiveText(deadline: deadline) else {
                throw CodexDaemonError.timeout
            }
            guard let data = text.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }

            // Server request: has both method and id -> NEVER answer! Only record.
            if let method = obj["method"] as? String, let idVal = obj["id"] {
                let idStr = String(describing: idVal)
                let params = obj["params"] as? [String: Any]
                let threadId = params?["threadId"] as? String
                let summary = (params?["command"] as? String) ?? (params?["reason"] as? String) ?? method
                _observedServerRequests.append(
                    CodexServerRequest(id: idStr, method: method, threadId: threadId, summary: summary)
                )
                continue
            }

            // Notification: has method, no id
            if let _ = obj["method"] as? String {
                _notifications.append(obj)
                if _notifications.count > 200 {
                    _notifications.removeFirst(_notifications.count - 200)
                }
                continue
            }

            // Response with matching id
            if let resId = obj["id"] as? Int, resId == expectedId {
                if let errorObj = obj["error"] as? [String: Any] {
                    let code = errorObj["code"] as? Int ?? -1
                    let message = errorObj["message"] as? String ?? "RPC error"
                    throw CodexDaemonError.rpc(code: code, message: message)
                }
                if let res = obj["result"] as? [String: Any] {
                    return res
                }
                return obj
            }
        }

        throw CodexDaemonError.timeout
    }

    public func loadedThreads() throws -> [String] {
        let res = try call("thread/loaded/list", [:])
        return (res["data"] as? [String]) ?? []
    }

    public func readThread(_ id: String) throws -> CodexThreadInfo {
        let res = try call("thread/read", ["threadId": id])
        let threadObj = (res["thread"] as? [String: Any]) ?? res
        let threadId = (threadObj["id"] as? String) ?? id
        let cwd = threadObj["cwd"] as? String
        let path = threadObj["path"] as? String
        let originator = threadObj["originator"] as? String

        let statusObj = threadObj["status"] as? [String: Any]
        let statusType = (statusObj?["type"] as? String) ?? "idle"
        let status: CodexThreadStatus
        switch statusType {
        case "notLoaded":
            status = .notLoaded
        case "systemError":
            status = .systemError
        case "active":
            let flags = (statusObj?["activeFlags"] as? [String]) ?? []
            status = .active(flags: flags)
        default:
            status = .idle
        }
        return CodexThreadInfo(id: threadId, cwd: cwd, path: path, originator: originator, status: status)
    }

    public func queueAdd(thread: String, text: String, clientID: String) throws -> String {
        let params: [String: Any] = [
            "threadId": thread,
            "clientUserMessageId": clientID,
            "input": [["type": "text", "text": text]]
        ]
        let res = try call("thread/queue/add", params)
        if let sub = res["queuedSubmission"] as? [String: Any],
           let subId = sub["id"] as? String {
            return subId
        }
        return (res["id"] as? String) ?? ""
    }

    public func turns(thread: String, limit: Int = 10) throws -> [CodexTurn] {
        let params: [String: Any] = [
            "threadId": thread,
            "limit": limit,
            "sortDirection": "desc"
        ]
        let res = try call("thread/turns/list", params)
        guard let list = res["data"] as? [[String: Any]] else { return [] }

        return list.compactMap { item in
            guard let id = item["id"] as? String,
                  let status = item["status"] as? String else { return nil }

            let startedAt: Date?
            if let s = (item["startedAt"] as? Double) ?? (item["startedAt"] as? Int).map(Double.init) {
                startedAt = Date(timeIntervalSince1970: s)
            } else {
                startedAt = nil
            }

            let completedAt: Date?
            if let c = (item["completedAt"] as? Double) ?? (item["completedAt"] as? Int).map(Double.init) {
                completedAt = Date(timeIntervalSince1970: c)
            } else {
                completedAt = nil
            }

            let errObj = item["error"] as? [String: Any]
            let errorMessage = errObj?["message"] as? String
            // `codexErrorInfo` is a bare string for unit variants or a one-key object for variants with data.
            let rawInfo = errObj?["codexErrorInfo"]
            let errorInfo = (rawInfo as? String) ?? (rawInfo as? [String: Any])?.keys.sorted().first

            var clientIDs: [String] = []
            var finalAnswer: String? = nil

            if let items = item["items"] as? [[String: Any]] {
                for subItem in items {
                    let type = subItem["type"] as? String
                    if type == "userMessage", let cid = subItem["clientId"] as? String {
                        clientIDs.append(cid)
                    } else if type == "agentMessage" {
                        let text = subItem["text"] as? String
                        let phase = subItem["phase"] as? String
                        if phase == "final_answer" || finalAnswer == nil {
                            finalAnswer = text
                        }
                    }
                }
            }

            return CodexTurn(
                id: id,
                status: status,
                startedAt: startedAt,
                completedAt: completedAt,
                clientIDs: clientIDs,
                finalAnswer: finalAnswer,
                errorMessage: errorMessage,
                errorInfo: errorInfo
            )
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        conn?.close()
        conn = nil
    }

    /// Pure helper: final answer of the earliest completed turn whose items contain clientID, else of the earliest
    /// turn with status completed and startedAt >= since - 2s. Failed turn -> nil (caller maps errorInfo).
    public static func reply(in turns: [CodexTurn], clientID: String?, since: Date?) -> String? {
        if let clientID, !clientID.isEmpty {
            let mine = turns.filter { $0.clientIDs.contains(clientID) }
            if !mine.isEmpty {
                // Our message is in a turn: answer only from that turn, never from a neighbour.
                let done = mine.filter { $0.status == "completed" && $0.finalAnswer != nil }
                return done.min(by: { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) })?.finalAnswer
            }
        }
        if let since {
            let cutoff = since.addingTimeInterval(-2.0)
            let matching = turns.filter {
                $0.status == "completed" && ($0.startedAt ?? .distantPast) >= cutoff && $0.finalAnswer != nil
            }
            if let earliest = matching.min(by: { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }) {
                return earliest.finalAnswer
            }
        }
        return nil
    }

    /// usageLimitExceeded / rateLimitExceeded -> true
    public static func isQuota(_ errorInfo: String?) -> Bool {
        guard let errorInfo else { return false }
        let lower = errorInfo.lowercased()
        return lower.contains("usagelimitexceeded") ||
               lower.contains("ratelimitexceeded") ||
               lower.contains("quota") ||
               lower.contains("429")
    }
}
