import Foundation

/// Reads Claude Code (`~/.claude/projects`) and Codex (`~/.codex/sessions`)
/// session histories for a project directory.
enum SessionsService {

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: Claude

    /// Claude encodes a project path by replacing "/" and "." with "-".
    /// Extracted for unit-testability.
    static func encodeClaudePath(_ path: String) -> String {
        String(path.map { ($0 == "/" || $0 == ".") ? "-" : $0 })
    }

    static func claudeSessions(for path: String) async -> [AgentSession] {
        await Task.detached(priority: .utility) {
            // Claude encodes the project path by replacing "/" and "." with "-".
            let encoded = SessionsService.encodeClaudePath(path)
            let dir = home.appendingPathComponent(".claude/projects/\(encoded)", isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }

            var out: [AgentSession] = []
            for f in files where f.pathExtension == "jsonl" {
                let id = f.deletingPathExtension().lastPathComponent
                let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let title = claudeTitle(f) ?? "session \(id.prefix(8))"
                out.append(AgentSession(id: id, kind: .claude, title: title, modified: mod, resumeCwd: path))
            }
            return out.sorted { $0.modified > $1.modified }
        }.value
    }

    private static func claudeTitle(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 256 * 1024) else { return nil }
        let text = String(decoding: chunk, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "user",
                  let msg = obj["message"] as? [String: Any] else { continue }
            if let s = msg["content"] as? String { return clip(s) }
            if let arr = msg["content"] as? [[String: Any]] {
                for item in arr where (item["type"] as? String) == "text" {
                    if let t = item["text"] as? String, !t.isEmpty { return clip(t) }
                }
            }
        }
        return nil
    }

    // MARK: Codex

    static func codexSessions(for path: String) async -> [AgentSession] {
        await Task.detached(priority: .utility) {
            // Rollout files carry the cwd in their first (session_meta) line.
            let sessionsDir = home.appendingPathComponent(".codex/sessions").path
            let pattern = "\"cwd\":\"\(path)\""
            let result = Shell.run("/usr/bin/grep",
                ["-rlF", "--include=rollout-*.jsonl", pattern, sessionsDir])
            let names = codexThreadNames()

            var out: [AgentSession] = []
            for filePath in result.out.split(separator: "\n").map(String.init) where !filePath.isEmpty {
                let url = URL(fileURLWithPath: filePath)
                let id = codexID(url) ?? url.deletingPathExtension().lastPathComponent
                let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let title = names[id].flatMap { $0.isEmpty ? nil : $0 } ?? "session \(id.prefix(8))"
                out.append(AgentSession(id: id, kind: .codex, title: title, modified: mod, resumeCwd: path))
            }
            return out.sorted { $0.modified > $1.modified }
        }.value
    }

    private static func codexID(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 8 * 1024),
              let line = String(decoding: chunk, as: UTF8.self).split(separator: "\n").first,
              let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let id = payload["id"] as? String else { return nil }
        return id
    }

    /// id -> thread_name from `~/.codex/session_index.jsonl` (nice titles).
    private static func codexThreadNames() -> [String: String] {
        let url = home.appendingPathComponent(".codex/session_index.jsonl")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        for line in content.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let id = obj["id"] as? String else { continue }
            if let name = obj["thread_name"] as? String { map[id] = name }
        }
        return map
    }

    private static func clip(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.count > 80 ? String(t.prefix(80)) + "…" : t
    }
}
