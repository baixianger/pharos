import Foundation

public struct CLIQuotaMark: Codable, Equatable, Sendable {
    public var model: String
    public var until: Date

    public init(model: String, until: Date) {
        self.model = model
        self.until = until
    }
}

/// Persisted at a JSON file (default `<light store dir>/cli-quota.json`, injectable URL; nil = memory only).
public final class CLIQuotaBook: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [String: [CLIQuotaMark]] = [:]
    private let store: URL?
    private let now: @Sendable () -> Date

    public static let defaultQuotaDuration: TimeInterval = 3600 // 1 hour

    public init(store: URL? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
        if store != nil {
            self.marks = loadLocked()
        }
    }

    public func mark(app: String, model: String, until: Date) {
        lock.lock()
        defer { lock.unlock() }
        if store != nil { marks = loadLocked() }
        var appMarks = marks[app] ?? []
        if let idx = appMarks.firstIndex(where: { $0.model == model }) {
            appMarks[idx].until = until
        } else {
            appMarks.append(CLIQuotaMark(model: model, until: until))
        }
        marks[app] = appMarks
        saveLocked()
    }

    public func exhausted(app: String, model: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if store != nil { marks = loadLocked() }
        guard let appMarks = marks[app],
              let found = appMarks.first(where: { $0.model == model }) else {
            return nil
        }
        if found.until > now() {
            return found.until
        }
        return nil
    }

    /// First model in `chain` not exhausted; nil if all are -> caller defers.
    public func pick(app: String, chain: [String]) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if store != nil { marks = loadLocked() }
        let currentTime = now()
        let appMarks = marks[app] ?? []
        for model in chain {
            if let found = appMarks.first(where: { $0.model == model }) {
                if found.until <= currentTime {
                    return model
                }
            } else {
                return model
            }
        }
        return nil
    }

    /// Earliest `until` among chain models (for the deferred retryAt).
    public func earliestReset(app: String, chain: [String]) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if store != nil { marks = loadLocked() }
        let currentTime = now()
        let appMarks = marks[app] ?? []
        let activeDates = chain.compactMap { model -> Date? in
            guard let found = appMarks.first(where: { $0.model == model }),
                  found.until > currentTime else {
                return nil
            }
            return found.until
        }
        return activeDates.min()
    }

    private func loadLocked() -> [String: [CLIQuotaMark]] {
        guard let store,
              let data = try? Data(contentsOf: store),
              let decoded = try? JSONDecoder().decode([String: [CLIQuotaMark]].self, from: data) else {
            return marks
        }
        return decoded
    }

    private func saveLocked() {
        guard let store,
              let data = try? JSONEncoder().encode(marks) else {
            return
        }
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: store, options: .atomic)
    }
}

public enum CLIModelChains {
    public static let agyDefaultChain: [String] = [
        "Gemini 3.8 Flash (High)",
        "Gemini 3.8 Flash (Medium)",
        "Gemini 3.8 Flash (Low)"
    ]

    public static func agy(env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        if let custom = env["PHAROS_AGY_MODELS"]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            let parts = custom.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !parts.isEmpty {
                return parts
            }
        }
        return agyDefaultChain
    }
}
