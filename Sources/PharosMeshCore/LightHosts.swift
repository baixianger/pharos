import Foundation

// MARK: - Mesh nodes and user-configured host aliases
//
// A Pharos node is named after its machine (the first label of the hostname,
// lowercased). Aliases are configured by the user only: there are no built-in
// short names. They live in ~/.config/pharos/hosts.json and are accepted
// anywhere a `--host` is.

/// One node in the Broker's roster (online or not).
public struct LightMeshNode: Codable, Equatable, Sendable {
    public var id: String
    /// The hostname the node heartbeats with.
    public var host: String
    public var tailscaleIP: String?
    public var lastSeen: Date
    /// The node runs on the Broker's machine (the hub that owns the light ledger).
    public var brokerLocal: Bool

    public init(id: String, host: String, tailscaleIP: String? = nil, lastSeen: Date, brokerLocal: Bool = false) {
        self.id = id
        self.host = host
        self.tailscaleIP = tailscaleIP
        self.lastSeen = lastSeen
        self.brokerLocal = brokerLocal
    }

    /// Node name: first hostname label, lowercased, safe as a member host label.
    public var name: String { LightHostDirectory.nodeName(host) }

    public func online(at now: Date) -> Bool {
        now.timeIntervalSince(lastSeen) < LightRelay.nodeHeartbeatWindow
    }

    public init(_ info: MeshNodeInfo) {
        self.init(id: info.id, host: info.host, tailscaleIP: info.tailscaleIP,
                  lastSeen: Date(timeIntervalSince1970: info.lastSeen), brokerLocal: info.brokerLocal == true)
    }
}

public struct LightHostsConfig: Codable, Equatable, Sendable {
    /// short alias -> node name
    public var aliases: [String: String]
    /// node name -> SSH destination used only as the backup route
    public var ssh: [String: String]

    public init(aliases: [String: String] = [:], ssh: [String: String] = [:]) {
        self.aliases = aliases
        self.ssh = ssh
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aliases = try container.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        ssh = try container.decodeIfPresent([String: String].self, forKey: .ssh) ?? [:]
    }
}

public enum LightHostsError: Error, Equatable, LocalizedError {
    case invalidAlias(String)
    case unknownNode(String)
    case aliasIsNodeName(String)
    case unknownAlias(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAlias(let value): "invalid alias \(value) (use a-z, 0-9 and -, starting with a letter, up to 32)"
        case .unknownNode(let value): "no Pharos node named \(value) (see pharos host list)"
        case .aliasIsNodeName(let value): "\(value) is already a node name"
        case .unknownAlias(let value): "no alias \(value)"
        case .unreadable(let value): "hosts file is unreadable (\(value))"
        }
    }
}

/// `~/.config/pharos/hosts.json` (override: `PHAROS_HOSTS_FILE`).
public struct LightHostsFile: Sendable {
    public var url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = env["PHAROS_HOSTS_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let home = env["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/pharos/hosts.json")
    }

    public static func standard(_ env: [String: String] = ProcessInfo.processInfo.environment) -> LightHostsFile {
        LightHostsFile(url: defaultURL(env))
    }

    public func load() -> LightHostsConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(LightHostsConfig.self, from: data) else { return LightHostsConfig() }
        return config
    }

    public func save(_ config: LightHostsConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Resolves `--host` labels against the roster and the user's aliases.
public struct LightHostDirectory: Sendable {
    public var nodes: [LightMeshNode]
    public var config: LightHostsConfig

    public init(nodes: [LightMeshNode], config: LightHostsConfig) {
        self.nodes = nodes
        self.config = config
    }

    public static func nodeName(_ host: String) -> String {
        let first = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".").first.map(String.init) ?? host
        var out = ""
        for scalar in first.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII { out.unicodeScalars.append(scalar) }
            else { out.append("-") }
        }
        while out.hasPrefix("-") || out.first?.isNumber == true { out.removeFirst() }
        if out.isEmpty { out = "node" }
        return String(out.prefix(63))
    }

    public static func validAlias(_ value: String) -> Bool {
        value.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil
    }

    /// Unique nodes by name, newest heartbeat first when a machine re-registered.
    public var roster: [LightMeshNode] {
        var byName: [String: LightMeshNode] = [:]
        for node in nodes {
            if let existing = byName[node.name], existing.lastSeen >= node.lastSeen { continue }
            byName[node.name] = node
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// The node a label names: an alias first, then a node name, node id, hostname, or Tailscale IP.
    public func node(for label: String) -> LightMeshNode? {
        let folded = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !folded.isEmpty else { return nil }
        let target = config.aliases[folded]?.lowercased() ?? folded
        let candidates = roster
        if let hit = candidates.first(where: { $0.name == target }) { return hit }
        if let hit = candidates.first(where: { $0.id.lowercased() == target || $0.host.lowercased() == target }) { return hit }
        if let hit = candidates.first(where: { $0.tailscaleIP == target }) { return hit }
        // A member registered under the node's SSH name (e.g. `mac-air`) is that node.
        if let entry = config.ssh.first(where: { $0.value.lowercased() == target }),
           let hit = candidates.first(where: { $0.name == entry.key.lowercased() }) { return hit }
        return nil
    }

    /// Canonical node name for a label, or the label itself (lowercased) when no node matches.
    public func canonical(_ label: String) -> String {
        node(for: label)?.name ?? label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func aliases(of nodeName: String) -> [String] {
        config.aliases.filter { $0.value.lowercased() == nodeName.lowercased() }.map(\.key).sorted()
    }

    /// The hub: the node on the Broker's machine.
    public var hub: LightMeshNode? {
        roster.filter(\.brokerLocal).max { $0.lastSeen < $1.lastSeen }
    }

    /// SSH destination for the backup route: the configured one, else a label that is
    /// not a Pharos name (an existing SSH alias), else the node's Tailscale IP.
    public func sshDestination(for label: String) -> String? {
        let folded = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !folded.isEmpty else { return nil }
        if let node = node(for: folded) {
            if let configured = config.ssh[node.name], !configured.isEmpty { return configured }
            if config.aliases[folded] == nil, folded != node.name, folded != node.id.lowercased(),
               node.tailscaleIP != folded { return label }
            return node.tailscaleIP ?? node.host
        }
        let target = config.aliases[folded]?.lowercased() ?? folded
        if let configured = config.ssh[target], !configured.isEmpty { return configured }
        return config.aliases[folded] == nil ? label : nil
    }

    // MARK: Edits

    public func alias(node label: String, as short: String, ssh: String? = nil) throws -> LightHostsConfig {
        let alias = short.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.validAlias(alias) else { throw LightHostsError.invalidAlias(short) }
        guard let node = node(for: label) else { throw LightHostsError.unknownNode(label) }
        if roster.contains(where: { $0.name == alias && $0.name != node.name }) { throw LightHostsError.aliasIsNodeName(alias) }
        var next = config
        next.aliases[alias] = node.name
        if let ssh = ssh?.trimmingCharacters(in: .whitespacesAndNewlines), !ssh.isEmpty { next.ssh[node.name] = ssh }
        return next
    }

    public func unalias(_ short: String) throws -> LightHostsConfig {
        let alias = short.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard config.aliases[alias] != nil else { throw LightHostsError.unknownAlias(short) }
        var next = config
        next.aliases[alias] = nil
        return next
    }
}
