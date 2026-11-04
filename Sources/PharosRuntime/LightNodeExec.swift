import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import PharosMeshCore

// What a Pharos node runs for its own machine when another node asks over the
// mesh (or over the SSH backup): deliver into a local session, read a local
// session's new answer, and the bounded background tick (spool, inbox, harvest).

public struct LightNodeDelivery: Codable, Equatable, Sendable {
    public var member: LightMember
    public var envelope: LightEnvelope
    public init(member: LightMember, envelope: LightEnvelope) {
        self.member = member
        self.envelope = envelope
    }
}

public struct LightNodeHarvest: Codable, Equatable, Sendable {
    public var member: LightMember
    public var since: Date
    public init(member: LightMember, since: Date) {
        self.member = member
        self.since = since
    }
}

public enum LightNodeExec {
    /// Commands a node accepts over the mesh (`light` node command). Nothing else runs.
    public static let allowed: Set<String> = [
        "session", "project", "member", "thread", "send", "reply", "wait", "read", "attention",
        "node-deliver", "node-harvest",
    ]

    public static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return data.base64EncodedString()
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        guard let data = Data(base64Encoded: text) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    /// `node-deliver --payload B64` / `node-harvest --payload B64`, run against this machine only.
    public static func execute(command: String, arguments: [String], driver: any LightSessionDriver) -> LightCLIResult {
        guard let index = arguments.firstIndex(of: "--payload"), index + 1 < arguments.count else {
            return LightCLIResult(exitCode: 2, text: "error: pharos \(command) --payload B64")
        }
        let payload = arguments[index + 1]
        switch command {
        case "node-deliver":
            guard let request = decode(LightNodeDelivery.self, payload) else {
                return LightCLIResult(exitCode: 2, text: "error: unreadable delivery payload")
            }
            let result = driver.deliver(member: request.member, envelope: request.envelope)
            return json([
                "ok": result.state == .delivered || result.state == .deferred,
                "state": result.state.rawValue, "route": result.route ?? NSNull(),
                "fallback": result.fallback, "detail": result.detail,
            ])
        case "node-harvest":
            guard let request = decode(LightNodeHarvest.self, payload) else {
                return LightCLIResult(exitCode: 2, text: "error: unreadable harvest payload")
            }
            let text = driver.readReply(member: request.member, since: request.since)
            return json(["ok": true, "text": text ?? NSNull()])
        default:
            return LightCLIResult(exitCode: 2, text: "error: unknown node command \(command)")
        }
    }

    static func json(_ body: [String: Any]) -> LightCLIResult {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return LightCLIResult(exitCode: 1, text: "error: could not encode the result")
        }
        return LightCLIResult(exitCode: 0, text: text)
    }
}

// MARK: - Reply spool

/// A drop-in folder for `pharos reply` when the caller is sandboxed (no socket,
/// no write outside its sandbox). The local Pharos node drains it. Folders, first
/// writable wins: `PHAROS_LIGHT_SPOOL`, `/private/tmp/pharos-spool-<uid>`, `$TMPDIR/pharos-spool`.
/// A spool file is a reply-id plus text: the same capability as running `pharos reply`.
public struct LightReplySpool: Sendable {
    public var directories: [URL]

    public init(directories: [URL]) { self.directories = directories }

    public static func standard(_ env: [String: String] = ProcessInfo.processInfo.environment) -> LightReplySpool {
        if let override = env["PHAROS_LIGHT_SPOOL"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return LightReplySpool(directories: [URL(fileURLWithPath: override, isDirectory: true)])
        }
        var dirs = [URL(fileURLWithPath: "/private/tmp/pharos-spool-\(getuid())", isDirectory: true)]
        let temp = (env["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory())
        dirs.append(URL(fileURLWithPath: temp, isDirectory: true).appendingPathComponent("pharos-spool", isDirectory: true))
        var seen = Set<String>()
        return LightReplySpool(directories: dirs.filter { seen.insert($0.standardizedFileURL.path).inserted })
    }

    public struct Item: Codable, Equatable, Sendable {
        public var v: Int
        public var argv: [String]
        public var createdAt: Date
        public init(argv: [String], createdAt: Date) {
            self.v = 1
            self.argv = argv
            self.createdAt = createdAt
        }
    }

    /// Write `argv` (`["reply", "r_x", ...]`) atomically. Returns the file, or nil when no folder is writable.
    public func write(argv: [String], now: Date = Date()) -> URL? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(Item(argv: argv, createdAt: now)) else { return nil }
        let name = "\(Int(now.timeIntervalSince1970 * 1000))-\(UUID().uuidString.lowercased().prefix(8))"
        for dir in directories {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let temp = dir.appendingPathComponent(".\(name).tmp")
                let final = dir.appendingPathComponent("\(name).json")
                try data.write(to: temp)
                chmod(temp.path, 0o600)
                guard rename(temp.path, final.path) == 0 else {
                    try? FileManager.default.removeItem(at: temp)
                    continue
                }
                return final
            } catch {
                continue
            }
        }
        return nil
    }

    public func pending() -> [URL] {
        directories.flatMap { dir -> [URL] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
                .map { dir.appendingPathComponent($0) }
        }
    }

    /// Hand each spooled reply to `handle` (true = recorded). Recorded and unreadable
    /// files are removed; a failing one is retried until it is an hour old, then set aside.
    @discardableResult
    public func drain(now: Date = Date(), handle: ([String]) -> Bool) -> Int {
        var done = 0
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        for url in pending() {
            guard let data = try? Data(contentsOf: url), let item = try? decoder.decode(Item.self, from: data),
                  item.argv.first == "reply" else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if handle(item.argv) {
                try? FileManager.default.removeItem(at: url)
                done += 1
            } else if now.timeIntervalSince(item.createdAt) > 3600 {
                let failed = url.deletingLastPathComponent().appendingPathComponent("failed", isDirectory: true)
                try? FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: url, to: failed.appendingPathComponent(url.lastPathComponent))
            }
        }
        return done
    }
}

// MARK: - Background tick

/// One bounded pass of the node's background work. Cheap when there is nothing to do.
/// Hub only (it owns the ledger): retry inbox jobs whose node is back, pump the
/// outbox, and harvest recent unanswered asks from read-only agents (replies are
/// harvested by the hub tick; `pharos wait` is a hidden test/script utility, capped at 300 s).
public struct LightTick {
    public var relay: LightRelay
    public var sessions: LightSessionService
    public var router: any LightNodeRouting
    /// How long after the ask Pharos keeps reading a session for its answer.
    public var harvestWindow: TimeInterval
    /// At most this many sessions read per tick.
    public var harvestLimit: Int

    /// Poll side of needs_human (apps without a hookable approval event). Nil skips it.
    public var attention: (any HumanAttentionSource)?

    public init(relay: LightRelay, sessions: LightSessionService, router: any LightNodeRouting,
                harvestWindow: TimeInterval = 30 * 60, harvestLimit: Int = 6,
                attention: (any HumanAttentionSource)? = nil) {
        self.attention = attention
        self.relay = relay
        self.sessions = sessions
        self.router = router
        self.harvestWindow = harvestWindow
        self.harvestLimit = harvestLimit
    }

    public struct Report: Codable, Equatable, Sendable {
        public var inboxRetried: Int = 0
        public var flushed: Int = 0
        public var harvested: [String] = []
        public var checked: Int = 0
        public var attention: Int = 0
    }

    public func run() -> Report {
        var report = Report()
        report.inboxRetried = sessions.drainInbox()
        // Before the sweep, so a state that just cleared flushes its queue this pass.
        if let attention {
            for observation in attention.poll(members: relay.attentionCandidates()) {
                if (try? relay.reportAttention(observation)) != nil { report.attention += 1 }
            }
        }
        report.flushed = relay.sweep().flushed
        for replyID in relay.pendingHarvest(maxAge: harvestWindow, limit: harvestLimit) {
            report.checked += 1
            if let result = try? relay.wait(replyID: replyID, timeout: 0), result.status == .replied {
                report.harvested.append(replyID)
            }
        }
        return report
    }
}
