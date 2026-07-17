import Foundation

/// Pure validation shared by the headless Host node and its tests. Client apps
/// never receive an API that can write to tmux.
public enum MeshPaneSafety {
    public static let busyLeaseSeconds: Double = 180
    public static let blockedLeaseSeconds: Double = 900

    /// Hooks own delivery only while their busy/blocked lease is fresh. A
    /// missing/unknown state is treated as expired and therefore pokeable: the
    /// product deliberately prefers eventual delivery over a permanent lock
    /// when an agent or hook disappears without publishing a final state.
    public static func allowsPoke(state: String?) -> Bool {
        guard let state, let value = MeshSessionState(rawValue: state) else { return false }
        return value.pokeable
    }

    public static func allowsPoke(state: String?, stateTs: Double?,
                                  now: Double = Date().timeIntervalSince1970) -> Bool {
        guard let state, let value = MeshSessionState(rawValue: state) else { return true }
        if value.pokeable { return true }
        if value == .gone { return false }
        guard let stateTs else { return true }
        guard stateTs <= now else { return false }
        let ttl = value == .blocked ? blockedLeaseSeconds : busyLeaseSeconds
        return now - stateTs > ttl
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

    /// Bootstrap-only compatibility probe for starting an interactive agent.
    /// Never use captured TUI text for session state, reconciliation, or poke
    /// eligibility; those decisions are exclusively hook-lease driven.
    public static func paneLooksIdle(_ output: String) -> Bool {
        let lines = output.components(separatedBy: .newlines)
        guard let composer = lines.lastIndex(where: { $0.contains("❯") || $0.contains("›") }) else {
            return false
        }
        let currentComposer = lines[composer].trimmingCharacters(in: .whitespaces)
        if currentComposer.range(of: #"^❯\s*\d+\."#, options: .regularExpression) != nil {
            return false
        }

        // Confirmation prompts use the same glyph as Claude's idle composer.
        // Only prompts appearing after the latest composer can still own input;
        // older prompts are merely scrollback from a completed interaction.
        let interactivePrompt = lines.lastIndex { line in
            let value = line.lowercased()
            return value.contains("do you want to proceed")
                || value.contains("enter to confirm")
                || value.contains("esc to cancel")
        }
        if let interactivePrompt, interactivePrompt >= composer { return false }

        // A captured pane contains scrollback, so arbitrary words such as
        // "while I was working" must not make an idle agent look busy. Match
        // actual TUI status markers and require a later turn-completion marker.
        let busy = lines.lastIndex { line in
            let value = line.trimmingCharacters(in: .whitespaces).lowercased()
            return value.contains("esc to interrupt")
                || value == "working"
                || value.hasPrefix("working (")
                || value.hasPrefix("• working")
                || (value.contains("shell command") && value.contains("…"))
                || (value.contains("… (") && value.contains("tokens)"))
        }
        if let busy {
            let completed = lines.lastIndex { line in
                let value = line.lowercased()
                // Claude deliberately varies the completion verb (Baked,
                // Churned, Sautéed, Cogitated, …). Match the stable elapsed
                // time grammar instead of maintaining a brittle verb list.
                return !value.contains("…")
                    && value.range(of: #"\bfor\s+\d+(?:m|s)"#,
                                   options: .regularExpression) != nil
            }
            guard let completed, completed > busy else { return false }
        }
        return true
    }

    /// Bootstrap-only recognition of native first-use workspace trust prompts.
    /// This does not report or infer mesh session state.
    public static func isKnownWorkspaceTrustPrompt(_ output: String) -> Bool {
        (output.contains("I trust this folder") && output.contains("Enter to confirm"))
            || (output.contains("Do you trust the contents of this directory?")
                && output.contains("Press enter to continue"))
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
