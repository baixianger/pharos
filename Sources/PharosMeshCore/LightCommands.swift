import Foundation

public struct LightCLIResult: Equatable, Sendable {
    public var exitCode: Int32
    public var text: String

    public init(exitCode: Int32, text: String) {
        self.exitCode = exitCode
        self.text = text
    }
}

/// Thin command surface over `LightRelay`. Parsing and formatting live here so
/// the macOS CLI and the tests cross the same seam.
public enum LightCommands {
    public static func execute(command: String, arguments: [String], relay: LightRelay,
                               routesForApp: (String) -> [LightRoute],
                               routeByID: (String) -> LightRoute = LightRoute.named) -> LightCLIResult {
        let argv = LightArgv.parse(arguments)
        do {
            switch command {
            case "member":
                return try member(argv, relay: relay, routesForApp: routesForApp, routeByID: routeByID)
            case "thread":
                return try thread(argv, relay: relay)
            case "send":
                return try send(argv, relay: relay)
            case "reply":
                return try reply(argv, relay: relay)
            case "wait":
                return try wait(argv, relay: relay)
            case "read":
                return try read(argv, relay: relay)
            default:
                return usage("unknown light command \(command)")
            }
        } catch let error as LightRelayError {
            let code: Int32 = {
                if case .emptyText = error { return 2 }
                return 1
            }()
            return LightCLIResult(exitCode: code, text: "error: \(error.localizedDescription)")
        } catch {
            return LightCLIResult(exitCode: 1, text: "error: \(error.localizedDescription)")
        }
    }

    private static func member(_ argv: LightArgv, relay: LightRelay,
                               routesForApp: (String) -> [LightRoute],
                               routeByID: (String) -> LightRoute) throws -> LightCLIResult {
        switch argv.positional.first {
        case "list", nil:
            let members = relay.listMembers()
            if argv.flag("json") { return json(members) }
            if members.isEmpty { return ok("no members") }
            let lines = members.map { member in
                let routes = member.routes.map(\.id).joined(separator: ",")
                return "\(member.name)\t\(member.app)\t\(member.host)\t\(member.project)\t\(member.sessionID)\t\(routes)"
            }
            return ok((["NAME\tAPP\tHOST\tPROJECT\tSESSION\tROUTES"] + lines).joined(separator: "\n"))
        case "register":
            guard let name = argv.option("name"), let host = argv.option("host"),
                  let app = argv.option("app"), let project = argv.option("project"),
                  let session = argv.option("session") else {
                return usage("pharos member register --name N --host H --app A --project P --session S [--route R]...")
            }
            let requested = argv.multi("route")
            let routes = requested.isEmpty ? routesForApp(app) : requested.map(routeByID)
            let member = try relay.register(LightMember(
                name: name, host: host, app: app, project: project, sessionID: session, routes: routes
            ))
            if argv.flag("json") { return json(member) }
            return ok("registered \(member.name)")
        default:
            return usage("pharos member register|list")
        }
    }

    private static func thread(_ argv: LightArgv, relay: LightRelay) throws -> LightCLIResult {
        switch argv.positional.first {
        case "list":
            let threads = relay.listThreads()
            if argv.flag("json") { return json(threads) }
            if threads.isEmpty { return ok("no threads") }
            let lines = threads.map { thread in
                let flag = thread.stopped ? "stopped" : "open"
                return "\(thread.id)\t\(flag)\t\(thread.hopLimit)\t\(thread.members.joined(separator: ","))"
            }
            return ok((["THREAD\tSTATE\tHOP\tMEMBERS"] + lines).joined(separator: "\n"))
        case "new":
            let names = argv.multi("member")
            guard names.count >= 2 else { return usage("pharos thread new --member A --member B [--hop-limit N]") }
            let hop = try argv.int("hop-limit")
            let thread = try relay.openThread(members: names, hopLimit: hop)
            if argv.flag("json") { return json(thread) }
            return ok("thread \(thread.id)")
        case "add":
            guard let id = argv.positional.dropFirst().first ?? argv.option("thread") else {
                return usage("pharos thread add <thread> --member NAME")
            }
            let names = argv.multi("member")
            guard !names.isEmpty else { return usage("pharos thread add <thread> --member NAME") }
            var thread: LightThread?
            for name in names {
                thread = try relay.addMember(name, to: id)
            }
            guard let thread else { return usage("pharos thread add <thread> --member NAME") }
            if argv.flag("json") { return json(thread) }
            return ok("thread \(thread.id)")
        default:
            return usage("pharos thread new|add|list")
        }
    }

    private static func send(_ argv: LightArgv, relay: LightRelay) throws -> LightCLIResult {
        guard let from = argv.option("from"), let thread = argv.option("thread") else {
            return usage("pharos send --from NAME --thread ID <text>")
        }
        let text = argv.positional.joined(separator: " ")
        guard !text.isEmpty else { return usage("pharos send --from NAME --thread ID <text>") }
        let result = try relay.send(from: from, thread: thread, text: text, ttl: try argv.duration("ttl"), once: argv.flag("once"))
        return render(result, json: argv.flag("json"))
    }

    private static func reply(_ argv: LightArgv, relay: LightRelay) throws -> LightCLIResult {
        guard let id = argv.positional.first else { return usage("pharos reply r_xxx <text>") }
        let text = argv.positional.dropFirst().joined(separator: " ")
        guard !text.isEmpty else { return usage("pharos reply r_xxx <text>") }
        let result = try relay.reply(id, text: text, ttl: try argv.duration("ttl"), once: argv.flag("once"))
        return render(result, json: argv.flag("json"))
    }

    private static func wait(_ argv: LightArgv, relay: LightRelay) throws -> LightCLIResult {
        guard let id = argv.positional.first else { return usage("pharos wait r_xxx [--timeout 30s]") }
        let timeout = try argv.duration("timeout") ?? 0
        let result = try relay.wait(replyID: id, timeout: timeout)
        if argv.flag("json") { return json(result, ok: result.status == .replied || result.status == .pending) }
        switch result.status {
        case .replied:
            return ok(result.text ?? "")
        case .pending:
            return ok("pending \(id)")
        case .expired:
            return LightCLIResult(exitCode: 1, text: "error: expired reply-id \(id)")
        case .unknown:
            return LightCLIResult(exitCode: 1, text: "error: unknown reply-id \(id)")
        }
    }

    private static func read(_ argv: LightArgv, relay: LightRelay) throws -> LightCLIResult {
        guard let thread = argv.option("thread") else { return usage("pharos read --thread ID") }
        let entries = try relay.read(thread: thread)
        if argv.flag("json") { return json(entries) }
        if entries.isEmpty { return ok("empty") }
        let lines = entries.map { entry -> String in
            switch entry.kind {
            case .message:
                return "message\t\(entry.from ?? "")\t\(entry.text)"
            case .notice:
                return "notice\t\(entry.text)"
            case .delivery:
                let route = entry.route ?? "-"
                let verified = (entry.liveVerified ?? false) ? "verified" : "unverified"
                return "delivery\t\(entry.to ?? "")\t\(entry.state?.rawValue ?? "")\t\(entry.replyID ?? "")\t\(route)\t\(verified)"
            }
        }
        return ok(lines.joined(separator: "\n"))
    }

    private static func render(_ result: LightSendResult, json: Bool) -> LightCLIResult {
        if json { return self.json(result) }
        if result.forwarded { return ok(result.notice ?? "forwarded") }
        var lines: [String] = []
        if result.stopped {
            lines.append("stopped \(result.threadID)")
        } else {
            lines.append("thread \(result.threadID) hop \(result.hop)/\(result.hopLimit)")
        }
        if let notice = result.notice { lines.append(notice) }
        for delivery in result.deliveries {
            let route = delivery.route ?? "-"
            let verified = delivery.liveVerified ? "verified" : "unverified"
            let fallback = delivery.fallback ? " fallback" : ""
            lines.append("\(delivery.state.rawValue)\t\(delivery.to)\t\(delivery.replyID)\t\(route)\t\(verified)\(fallback)")
        }
        if !result.unresolved.isEmpty {
            lines.append("unresolved \(result.unresolved.joined(separator: ","))")
        }
        return ok(lines.joined(separator: "\n"))
    }

    private static func ok(_ text: String) -> LightCLIResult {
        LightCLIResult(exitCode: 0, text: text)
    }

    private static func usage(_ text: String) -> LightCLIResult {
        LightCLIResult(exitCode: 2, text: "error: \(text)")
    }

    private static func json<T: Encodable>(_ value: T, ok: Bool = true) -> LightCLIResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return LightCLIResult(exitCode: 1, text: "error: could not encode the result")
        }
        return LightCLIResult(exitCode: ok ? 0 : 1, text: text)
    }
}

private struct LightArgv {
    var positional: [String] = []
    var options: [String: String] = [:]
    var repeated: [String: [String]] = [:]
    var flags: Set<String> = []

    static let knownFlags: Set<String> = ["json", "once"]
    static let repeatedKeys: Set<String> = ["route", "member"]

    static func parse(_ tokens: [String]) -> LightArgv {
        var argv = LightArgv()
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                argv.positional.append(contentsOf: tokens[(index + 1)...])
                break
            }
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                let key: String
                let inline: String?
                if let eq = body.firstIndex(of: "=") {
                    key = String(body[..<eq])
                    inline = String(body[body.index(after: eq)...])
                } else {
                    key = body
                    inline = nil
                }
                if let inline {
                    argv.options[key] = inline
                    argv.repeated[key, default: []].append(inline)
                } else if knownFlags.contains(key) {
                    argv.flags.insert(key)
                } else if index + 1 < tokens.count, !tokens[index + 1].hasPrefix("-") {
                    let value = tokens[index + 1]
                    argv.options[key] = value
                    argv.repeated[key, default: []].append(value)
                    index += 1
                } else {
                    argv.flags.insert(key)
                }
            } else {
                argv.positional.append(token)
            }
            index += 1
        }
        return argv
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func option(_ name: String) -> String? { options[name] }
    func multi(_ name: String) -> [String] { repeated[name] ?? [] }

    func int(_ name: String) throws -> Int? {
        guard let raw = options[name] else { return nil }
        guard let value = Int(raw), value >= 1 else { throw LightRelayError.invalidName(raw) }
        return value
    }

    func duration(_ name: String) throws -> TimeInterval? {
        guard let raw = options[name] else { return nil }
        return try Self.parseDuration(raw)
    }

    static func parseDuration(_ raw: String) throws -> TimeInterval {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed), seconds >= 0 { return seconds }
        guard let suffix = trimmed.last, let number = Double(trimmed.dropLast()), number >= 0 else {
            throw LightRelayError.invalidName(raw)
        }
        switch suffix {
        case "s": return number
        case "m": return number * 60
        case "h": return number * 60 * 60
        case "d": return number * 24 * 60 * 60
        default: throw LightRelayError.invalidName(raw)
        }
    }
}
