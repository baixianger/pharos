import Foundation

public struct LightSessionEntry: Codable, Equatable, Sendable {
    public var app: String            // codex | agy | cursor
    public var id: String
    public var cwd: String?
    public var project: String?       // last path component of cwd
    public var title: String?         // app's own title/name only
    public var lastActive: Date?
    public var state: String?         // idle | active | needs_human | notLoaded | unknown
    public var source: String?        // e.g. codex "cli"/"vscode"

    public init(
        app: String,
        id: String,
        cwd: String? = nil,
        project: String? = nil,
        title: String? = nil,
        lastActive: Date? = nil,
        state: String? = nil,
        source: String? = nil
    ) {
        self.app = app
        self.id = id
        self.cwd = cwd
        if let project {
            self.project = project
        } else if let cwd, !cwd.isEmpty {
            self.project = URL(fileURLWithPath: cwd).lastPathComponent
        } else {
            self.project = nil
        }
        self.title = title
        self.lastActive = lastActive
        self.state = state
        self.source = source
    }
}

public struct LightNodeInventory: Codable, Equatable, Sendable {
    public var node: String
    public var at: Date
    public var sessions: [LightSessionEntry]
    public var notes: [String]        // e.g. "codex: daemon not running, read rollouts"

    public init(
        node: String,
        at: Date = Date(),
        sessions: [LightSessionEntry] = [],
        notes: [String] = []
    ) {
        self.node = node
        self.at = at
        self.sessions = sessions
        self.notes = notes
    }
}

public struct LightWorkspace: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var source: String         // "derived" | "manual"
    public var apps: [String]

    public init(name: String, path: String, source: String, apps: [String] = []) {
        self.name = name
        self.path = path
        self.source = source
        self.apps = apps
    }
}

public struct LightInventoryStore: Sendable {
    public var rootDir: URL

    public static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    public static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    public init(rootDir: URL = LightRelay.defaultStoreURL()) {
        self.rootDir = rootDir
    }

    public var inventoryDir: URL {
        rootDir.appendingPathComponent("inventory", isDirectory: true)
    }

    public func fileURL(for node: String) -> URL {
        inventoryDir.appendingPathComponent("\(node).json")
    }

    public func save(node: String, inventory: LightNodeInventory) throws {
        try FileManager.default.createDirectory(at: inventoryDir, withIntermediateDirectories: true)
        let data = try Self.jsonEncoder.encode(inventory)
        let target = fileURL(for: node)
        try Self.writeSecure(data: data, to: target)

        // Derive and update workspaces for this node
        let wsStore = LightWorkspaceStore(rootDir: rootDir)
        try wsStore.updateDerived(node: node, sessions: inventory.sessions)
    }

    public func load(node: String) -> LightNodeInventory? {
        let url = fileURL(for: node)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.jsonDecoder.decode(LightNodeInventory.self, from: data)
    }

    public func loadAll() -> [String: LightNodeInventory] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: inventoryDir, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var result: [String: LightNodeInventory] = [:]
        for file in files where file.pathExtension == "json" {
            let node = file.deletingPathExtension().lastPathComponent
            if let inv = load(node: node) {
                result[node] = inv
            }
        }
        return result
    }

    public static func writeSecure(data: Data, to target: URL) throws {
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temp)
        #if canImport(Darwin) || canImport(Glibc)
        chmod(temp.path, S_IRUSR | S_IWUSR)
        #endif
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: temp, to: target)
    }
}

public struct LightWorkspaceStore: Sendable {
    public var rootDir: URL

    public init(rootDir: URL = LightRelay.defaultStoreURL()) {
        self.rootDir = rootDir
    }

    public var fileURL: URL {
        rootDir.appendingPathComponent("workspaces.json")
    }

    public func loadAll() -> [String: [LightWorkspace]] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? LightInventoryStore.jsonDecoder.decode([String: [LightWorkspace]].self, from: data)) ?? [:]
    }

    public func workspaces(for node: String) -> [LightWorkspace] {
        let all = loadAll()
        return all[node] ?? []
    }

    public func saveAll(_ all: [String: [LightWorkspace]]) throws {
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let data = try LightInventoryStore.jsonEncoder.encode(all)
        try LightInventoryStore.writeSecure(data: data, to: fileURL)
    }

    public func addManual(node: String, path: String, name: String?) throws -> LightWorkspace {
        var all = loadAll()
        var current = all[node] ?? []

        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let finalName: String
        if let name, !name.isEmpty {
            finalName = name
        } else {
            finalName = Self.sanitizeWorkspaceName(URL(fileURLWithPath: resolvedPath).lastPathComponent)
        }

        // Check if path or name already exists
        if let idx = current.firstIndex(where: { $0.path == resolvedPath }) {
            current[idx].name = finalName
            current[idx].source = "manual"
            all[node] = current
            try saveAll(all)
            return current[idx]
        }

        let ws = LightWorkspace(name: finalName, path: resolvedPath, source: "manual", apps: [])
        current.append(ws)
        all[node] = current
        try saveAll(all)
        return ws
    }

    public func updateDerived(node: String, sessions: [LightSessionEntry]) throws {
        var all = loadAll()
        let existing = all[node] ?? []

        // Map cwds to the apps active in that cwd
        var cwdApps: [String: Set<String>] = [:]
        for s in sessions {
            guard let cwd = s.cwd, !cwd.isEmpty else { continue }
            let res = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
            cwdApps[res, default: []].insert(s.app)
        }

        var updated: [LightWorkspace] = []
        var usedNames: Set<String> = []

        // 1. Preserve existing manual workspaces
        for ws in existing where ws.source == "manual" {
            var item = ws
            if let apps = cwdApps[ws.path] {
                item.apps = Array(Set(item.apps).union(apps)).sorted()
            }
            updated.append(item)
            usedNames.insert(item.name)
        }

        // 2. Existing derived workspaces whose paths are in cwdApps keep their names!
        for ws in existing where ws.source == "derived" {
            if let apps = cwdApps[ws.path] {
                var item = ws
                item.apps = Array(Set(item.apps).union(apps)).sorted()
                updated.append(item)
                usedNames.insert(item.name)
            }
        }

        // 3. Collect distinct new cwds in the order they appear in `sessions`
        var orderedCwds: [String] = []
        for s in sessions {
            guard let cwd = s.cwd, !cwd.isEmpty else { continue }
            let res = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
            if !orderedCwds.contains(res) && !updated.contains(where: { $0.path == res }) {
                orderedCwds.append(res)
            }
        }

        for cwd in orderedCwds {
            let apps = Array(cwdApps[cwd] ?? []).sorted()
            let base = Self.sanitizeWorkspaceName(URL(fileURLWithPath: cwd).lastPathComponent)
            let assignedName: String
            if !usedNames.contains(base) {
                assignedName = base
            } else {
                var counter = 2
                var candidate = "\(base)-\(counter)"
                while usedNames.contains(candidate) {
                    counter += 1
                    candidate = "\(base)-\(counter)"
                }
                assignedName = candidate
            }
            usedNames.insert(assignedName)
            updated.append(LightWorkspace(name: assignedName, path: cwd, source: "derived", apps: apps))
        }

        // 4. Retain any previously derived workspaces that were NOT in cwdApps (keep them if no collision)
        for ws in existing where ws.source == "derived" {
            if !updated.contains(where: { $0.path == ws.path }) {
                if !usedNames.contains(ws.name) {
                    usedNames.insert(ws.name)
                    updated.append(ws)
                }
            }
        }

        all[node] = updated.sorted(by: { $0.name < $1.name })
        try saveAll(all)
    }

    public static func sanitizeWorkspaceName(_ raw: String) -> String {
        let lower = raw.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        var sanitized = lower.components(separatedBy: allowed.inverted).joined(separator: "-")
        while sanitized.contains("--") {
            sanitized = sanitized.replacingOccurrences(of: "--", with: "-")
        }
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "workspace" : sanitized
    }
}

public enum LightDirectory {
    public enum ResolveError: LocalizedError, Equatable {
        case invalidFormat(String)
        case unknownHost(String)
        case noSession(String)
        case ambiguous([String])

        public var errorDescription: String? {
            switch self {
            case .invalidFormat(let msg): return "invalid address: \(msg)"
            case .unknownHost(let host): return "unknown host: \(host)"
            case .noSession(let desc): return "no session \(desc)"
            case .ambiguous(let candidates): return "ambiguous: \(candidates.joined(separator: ", "))"
            }
        }
    }

    /// Resolves `<host>/<app>/<project>/<session>` or `<host>/<app>/<session>`
    public static func resolve(
        _ address: String,
        inventoryStore: LightInventoryStore = LightInventoryStore(),
        canonicalHost: (String) -> String = { $0 }
    ) throws -> (host: String, app: String, entry: LightSessionEntry) {
        let parts = address.split(separator: "/").map(String.init)
        let hostRaw: String
        let appRaw: String
        let projectRaw: String?
        let sessionPrefix: String

        if parts.count == 4 {
            hostRaw = parts[0]
            appRaw = parts[1]
            projectRaw = parts[2] == "-" ? nil : parts[2]
            sessionPrefix = parts[3]
        } else if parts.count == 3 {
            hostRaw = parts[0]
            appRaw = parts[1]
            projectRaw = nil
            sessionPrefix = parts[2]
        } else {
            throw ResolveError.invalidFormat(address)
        }

        let host = canonicalHost(hostRaw)
        guard let inventory = inventoryStore.load(node: host) else {
            throw ResolveError.unknownHost(host)
        }

        let app = appRaw.lowercased()
        var candidates = inventory.sessions.filter { $0.app.lowercased() == app }

        if let projectRaw, !projectRaw.isEmpty {
            let wsStore = LightWorkspaceStore(rootDir: inventoryStore.rootDir)
            let workspaces = wsStore.workspaces(for: host)
            let matchingWs = workspaces.first(where: { $0.name.lowercased() == projectRaw.lowercased() })
            candidates = candidates.filter { s in
                if let p = s.project, p.lowercased() == projectRaw.lowercased() {
                    return true
                }
                if let cwd = s.cwd, let ws = matchingWs, cwd == ws.path {
                    return true
                }
                return false
            }
        }

        // Session ID matching
        let matched = candidates.filter { s in
            if s.id == sessionPrefix { return true }
            if sessionPrefix.count >= 4 && s.id.hasPrefix(sessionPrefix) { return true }
            return false
        }

        if matched.isEmpty {
            throw ResolveError.noSession("matching \(address)")
        }
        if matched.count > 1 {
            throw ResolveError.ambiguous(matched.map(\.id))
        }

        return (host: host, app: app, entry: matched[0])
    }
}
