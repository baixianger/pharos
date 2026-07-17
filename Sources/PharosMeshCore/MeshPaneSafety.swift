import Foundation

/// Pure validation shared by the headless Host node and its tests. Client apps
/// never receive an API that can write to tmux.
public enum MeshPaneSafety {
    /// Hooks own delivery while an agent is running or blocked. The Host node
    /// may type only when the Broker has an explicit turn-boundary state.
    public static func allowsPoke(state: String?) -> Bool {
        guard let state, let value = MeshSessionState(rawValue: state) else { return false }
        return value.pokeable
    }

    public static func processTreeContainsAgent(_ output: String, rootPID: Int, kind: String?) -> Bool {
        struct Row { let pid: Int; let parent: Int; let executable: String }
        let rows: [Row] = output.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int(fields[0]), let parent = Int(fields[1]) else { return nil }
            return Row(pid: pid, parent: parent, executable: String(fields[2]))
        }
        var descendants: Set<Int> = [rootPID]
        var changed = true
        while changed {
            changed = false
            for row in rows where descendants.contains(row.parent) && !descendants.contains(row.pid) {
                descendants.insert(row.pid)
                changed = true
            }
        }
        return rows.contains { descendants.contains($0.pid) && isAgent($0.executable, kind: kind) }
    }

    public static func paneLooksIdle(_ output: String) -> Bool {
        let value = output.lowercased()
        if value.contains("esc to interrupt") || value.contains("working")
            || value.contains("do you want to proceed") || value.contains("enter to confirm")
            || value.contains("esc to cancel") { return false }
        return output.contains("❯") || output.contains("›")
    }

    private static func isAgent(_ path: String, kind: String?) -> Bool {
        let executable = URL(fileURLWithPath: path).lastPathComponent
        let codex = executable.hasPrefix("codex")
        let claude = ["claude", "node", "bun"].contains(executable)
            || executable.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
        if kind == "codex" { return codex }
        if kind == "claude" { return claude }
        return codex || claude
    }
}
