import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import PharosMeshCore

// MARK: - Webhook members
//
// A webhook member is a remote assistant reached by HTTPS POST. Each member names a
// webhook config (its session id). Configs live outside any repo, in
// ~/.config/pharos/webhooks.json (mode 600), keyed by name: URL, header name, secret.
// The secret is never taken from argv and never printed.

public struct LightWebhookConfig: Codable, Equatable, Sendable {
    public var url: String
    public var headerName: String
    public var secret: String

    public init(url: String, headerName: String, secret: String) {
        self.url = url
        self.headerName = headerName
        self.secret = secret
    }

    /// Scheme, host, and port only. Paths and queries can carry tokens.
    public var displayURL: String {
        guard let parsed = URL(string: url), let scheme = parsed.scheme, let host = parsed.host else { return "***" }
        let port = parsed.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}

public enum LightWebhookError: Error, Equatable, LocalizedError {
    case invalidName(String)
    case invalidURL(String)
    case invalidHeader(String)
    case missingSecret
    case unknownWebhook(String)
    case unreadableStore(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let value): "invalid webhook name \(value)"
        case .invalidURL(let value): "webhook URL must be https (http only for loopback): \(value)"
        case .invalidHeader(let value): "invalid header name \(value)"
        case .missingSecret: "a new webhook needs a secret: --secret-stdin, --secret-file PATH, or --secret-env VAR"
        case .unknownWebhook(let value): "unknown webhook \(value)"
        case .unreadableStore(let value): "webhook store is unreadable (\(value))"
        }
    }
}

public struct LightWebhookStore: Sendable {
    public let url: URL

    public init(url: URL = LightWebhookStore.defaultURL()) {
        self.url = url
    }

    /// `PHAROS_WEBHOOKS_FILE`, else ~/.config/pharos/webhooks.json.
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["PHAROS_WEBHOOKS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/pharos/webhooks.json")
    }

    private struct File: Codable {
        var version: Int
        var webhooks: [String: LightWebhookConfig]
    }

    public func all() throws -> [String: LightWebhookConfig] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).webhooks
        } catch {
            throw LightWebhookError.unreadableStore(url.lastPathComponent)
        }
    }

    public func config(named name: String) throws -> LightWebhookConfig? {
        try all()[name]
    }

    public func set(_ name: String, url raw: String?, headerName: String?, secret: String?) throws -> LightWebhookConfig {
        let key = try Self.validateName(name)
        var configs = try all()
        let existing = configs[key]
        guard let address = raw ?? existing?.url else { throw LightWebhookError.invalidURL("(none)") }
        try Self.validateURL(address)
        let header = headerName ?? existing?.headerName ?? "X-Pharos-Secret"
        guard header.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,63}$"#, options: .regularExpression) != nil else {
            throw LightWebhookError.invalidHeader(header)
        }
        let value = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key2 = (value?.isEmpty == false ? value : nil) ?? existing?.secret else {
            throw LightWebhookError.missingSecret
        }
        let config = LightWebhookConfig(url: address, headerName: header, secret: key2)
        configs[key] = config
        try write(configs)
        return config
    }

    @discardableResult
    public func remove(_ name: String) throws -> Bool {
        var configs = try all()
        guard configs.removeValue(forKey: name) != nil else { return false }
        try write(configs)
        return true
    }

    private func write(_ configs: [String: LightWebhookConfig]) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o700)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(version: 1, webhooks: configs))
        // Create with 600 before the secret is written.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        chmod(url.path, 0o600)
        try data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    static func validateName(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[a-z][a-z0-9-]{0,62}$"#, options: .regularExpression) != nil else {
            throw LightWebhookError.invalidName(value)
        }
        return value
    }

    static func validateURL(_ raw: String) throws {
        guard let parsed = URL(string: raw), let scheme = parsed.scheme?.lowercased(), let host = parsed.host?.lowercased() else {
            throw LightWebhookError.invalidURL(raw)
        }
        if scheme == "https" { return }
        if scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(host) { return }
        throw LightWebhookError.invalidURL(raw)
    }
}

/// Posts one envelope. The shipped poster uses URLSession; tests may inject another.
public protocol LightWebhookPosting: Sendable {
    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) -> (status: Int, detail: String)
}

public struct URLSessionWebhookPoster: LightWebhookPosting {
    public init() {}

    public func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) -> (status: Int, detail: String) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let semaphore = DispatchSemaphore(value: 0)
        let box = WebhookResultBox()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse {
                box.set(http.statusCode, "HTTP \(http.statusCode)")
            } else {
                box.set(0, error?.localizedDescription ?? "no response")
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            return (0, "timed out")
        }
        session.finishTasksAndInvalidate()
        return box.get()
    }
}

private final class WebhookResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Int, String) = (0, "no response")
    func set(_ status: Int, _ detail: String) { lock.lock(); value = (status, detail); lock.unlock() }
    func get() -> (status: Int, detail: String) { lock.lock(); defer { lock.unlock() }; return value }
}

public enum LightWebhookDelivery {
    /// POST the envelope to the member's named config. Never logs the secret.
    public static func deliver(member: LightMember, envelope: LightEnvelope, store: LightWebhookStore,
                               poster: any LightWebhookPosting, timeout: TimeInterval = 15) -> LightDriveResult {
        let config: LightWebhookConfig?
        do {
            config = try store.config(named: member.sessionID)
        } catch {
            return LightDriveResult(state: .failed, route: "webhook", fallback: false, liveVerified: false,
                                    detail: error.localizedDescription)
        }
        guard let config, let url = URL(string: config.url) else {
            return LightDriveResult(state: .failed, route: "webhook", fallback: false, liveVerified: false,
                                    detail: "webhook \(member.sessionID) is not configured (pharos webhook set)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(envelope) else {
            return LightDriveResult(state: .failed, route: "webhook", fallback: false, liveVerified: false,
                                    detail: "could not encode the envelope")
        }
        let headers = ["Content-Type": "application/json", "User-Agent": "pharos-light", config.headerName: config.secret]
        let result = poster.post(url: url, headers: headers, body: body, timeout: timeout)
        if (200..<300).contains(result.status) {
            return LightDriveResult(state: .delivered, route: "webhook", fallback: false, liveVerified: false,
                                    detail: "webhook \(member.sessionID) \(config.displayURL) \(result.detail)")
        }
        return LightDriveResult(state: .failed, route: "webhook", fallback: false, liveVerified: false,
                                detail: "webhook \(member.sessionID) \(config.displayURL) \(result.detail)")
    }
}

/// `pharos webhook set|list|show|remove`.
public enum LightWebhookCommands {
    public static let usage = "pharos webhook set NAME --url URL [--header-name H] (--secret-stdin | --secret-file PATH | --secret-env VAR) | list [--json] | show NAME | remove NAME"

    public static func execute(arguments: [String], store: LightWebhookStore,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               readStdin: () -> String? = { String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) }) -> LightCLIResult {
        var positional: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if ["json", "secret-stdin"].contains(key) {
                    flags.insert(key)
                } else if key == "secret" || key.hasPrefix("secret=") {
                    return LightCLIResult(exitCode: 2, text: "error: the secret is never taken from argv; use --secret-stdin, --secret-file PATH, or --secret-env VAR")
                } else if index + 1 < arguments.count {
                    options[key] = arguments[index + 1]
                    index += 1
                } else {
                    return LightCLIResult(exitCode: 2, text: "error: \(usage)")
                }
            } else {
                positional.append(token)
            }
            index += 1
        }
        do {
            switch positional.first {
            case "set", "add":
                guard positional.count == 2 else { return LightCLIResult(exitCode: 2, text: "error: \(usage)") }
                var secret: String? = nil
                if flags.contains("secret-stdin") {
                    secret = readStdin()
                } else if let path = options["secret-file"] {
                    secret = try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
                } else if let variable = options["secret-env"] {
                    guard let value = environment[variable], !value.isEmpty else {
                        return LightCLIResult(exitCode: 1, text: "error: environment variable \(variable) is empty")
                    }
                    secret = value
                }
                let config = try store.set(positional[1], url: options["url"], headerName: options["header-name"], secret: secret)
                return LightCLIResult(exitCode: 0, text: "webhook \(positional[1]) \(config.displayURL) header \(config.headerName) secret ***")
            case "list", nil:
                let configs = try store.all()
                if flags.contains("json") {
                    let rows = configs.keys.sorted().map { name -> [String: String] in
                        let config = configs[name]!
                        return ["name": name, "url": config.displayURL, "headerName": config.headerName, "secret": "***"]
                    }
                    let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                    return LightCLIResult(exitCode: 0, text: String(data: data, encoding: .utf8) ?? "[]")
                }
                if configs.isEmpty { return LightCLIResult(exitCode: 0, text: "no webhooks") }
                let lines = configs.keys.sorted().map { name in
                    "\(name)\t\(configs[name]!.displayURL)\t\(configs[name]!.headerName)\t***"
                }
                return LightCLIResult(exitCode: 0, text: (["NAME\tURL\tHEADER\tSECRET"] + lines).joined(separator: "\n"))
            case "show":
                guard positional.count == 2 else { return LightCLIResult(exitCode: 2, text: "error: \(usage)") }
                guard let config = try store.config(named: positional[1]) else {
                    throw LightWebhookError.unknownWebhook(positional[1])
                }
                return LightCLIResult(exitCode: 0, text: "name \(positional[1])\nurl \(config.displayURL)\nheader \(config.headerName)\nsecret ***")
            case "remove", "rm":
                guard positional.count == 2 else { return LightCLIResult(exitCode: 2, text: "error: \(usage)") }
                guard try store.remove(positional[1]) else { throw LightWebhookError.unknownWebhook(positional[1]) }
                return LightCLIResult(exitCode: 0, text: "removed webhook \(positional[1])")
            default:
                return LightCLIResult(exitCode: 2, text: "error: \(usage)")
            }
        } catch {
            return LightCLIResult(exitCode: 1, text: "error: \(error.localizedDescription)")
        }
    }
}
