import Foundation
import PharosMeshCore

public enum CLIAgentActivity: String, Codable, Sendable, Equatable {
    case idle
    case thinking
    case needsHuman = "needs_human"
    case unknown
}

public struct TmuxLiveness: Equatable, Sendable {
    public var tmuxAlive: Bool        // `tmux has-session -t =NAME` exit 0
    public var agentAlive: Bool       // pane process alive AND (if binding has agentStarted) same start time
    public var panePID: Int32?
    public var paneCommand: String?   // #{pane_current_command}
    public var paneDead: Bool         // #{pane_dead} == "1"

    /// "alive" | "agent-exited" | "dead" (tmux session gone)
    public var label: String {
        if !tmuxAlive {
            return "dead"
        }
        if agentAlive {
            return "alive"
        }
        return "agent-exited"
    }

    public init(
        tmuxAlive: Bool,
        agentAlive: Bool,
        panePID: Int32? = nil,
        paneCommand: String? = nil,
        paneDead: Bool = false
    ) {
        self.tmuxAlive = tmuxAlive
        self.agentAlive = agentAlive
        self.panePID = panePID
        self.paneCommand = paneCommand
        self.paneDead = paneDead
    }
}

public struct TmuxController: Sendable {
    public var tmux: String           // tmux binary path
    public var runner: any LightProcessRunning
    /// Pause between the typed text and Enter. TUIs with paste detection (codex) treat an
    /// Enter that arrives with the text as a newline, so live use sets this (~0.6s).
    public var enterDelay: TimeInterval

    public init(tmux: String = "tmux", runner: any LightProcessRunning, enterDelay: TimeInterval = 0) {
        self.tmux = tmux
        self.runner = runner
        self.enterDelay = enterDelay
    }

    /// `tmux has-session -t =NAME` exit 0
    public func hasSession(_ name: String) -> Bool {
        let invocation = LightInvocation(
            argv: [tmux, "has-session", "-t", "=\(name)"],
            stdin: "",
            executable: true,
            fallback: false,
            summary: "tmux has-session \(name)",
            loopback: true
        )
        let output = runner.run(invocation, stdin: "")
        return output.status == 0
    }

    /// `tmux new-session -d -s NAME -x 200 -y 50 -c CWD -- argv...` and `set-option -t =NAME: remain-on-exit on`
    /// (so a crashed CLI leaves a dead pane we can detect and respawn). Returns nil on success or the stderr text.
    public func newSession(name: String, cwd: String, argv: [String], env: [String: String] = [:]) -> String? {
        var newSessionArgs = [tmux, "new-session", "-d", "-s", name]
        for (k, v) in env.sorted(by: { $0.key < $1.key }) {
            newSessionArgs.append(contentsOf: ["-e", "\(k)=\(v)"])
        }
        newSessionArgs.append(contentsOf: ["-x", "200", "-y", "50", "-c", cwd, "--"])
        newSessionArgs.append(contentsOf: argv)

        let newOut = runner.run(
            LightInvocation(
                argv: newSessionArgs,
                stdin: "",
                executable: true,
                fallback: false,
                summary: "tmux new-session \(name)",
                loopback: true,
                cwd: cwd
            ),
            stdin: ""
        )
        guard newOut.status == 0 else {
            let err = newOut.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return err.isEmpty ? "tmux new-session exited with status \(newOut.status)" : err
        }

        let setOptArgs = [tmux, "set-option", "-t", "=\(name):", "remain-on-exit", "on"]
        let setOptOut = runner.run(
            LightInvocation(
                argv: setOptArgs,
                stdin: "",
                executable: true,
                fallback: false,
                summary: "tmux set-option \(name)",
                loopback: true
            ),
            stdin: ""
        )
        guard setOptOut.status == 0 else {
            let err = setOptOut.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return err.isEmpty ? "tmux set-option exited with status \(setOptOut.status)" : err
        }

        return nil
    }

    /// Relaunch inside an existing session whose pane is dead: `tmux respawn-pane -k -t =NAME: -c CWD -- argv...`
    /// Only call when the agent is not alive (the caller checks).
    public func respawn(name: String, cwd: String, argv: [String]) -> String? {
        var respawnArgs = [tmux, "respawn-pane", "-k", "-t", "=\(name):", "-c", cwd, "--"]
        respawnArgs.append(contentsOf: argv)

        let out = runner.run(
            LightInvocation(
                argv: respawnArgs,
                stdin: "",
                executable: true,
                fallback: false,
                summary: "tmux respawn-pane \(name)",
                loopback: true,
                cwd: cwd
            ),
            stdin: ""
        )
        guard out.status == 0 else {
            let err = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return err.isEmpty ? "tmux respawn-pane exited with status \(out.status)" : err
        }
        return nil
    }

    /// `list-panes -t =NAME: -F '#{pane_pid}\t#{pane_current_command}\t#{pane_dead}'` (first line)
    public func pane(_ name: String) -> (pid: Int32, command: String, dead: Bool)? {
        let args = [tmux, "list-panes", "-t", "=\(name):", "-F", "#{pane_pid}\t#{pane_current_command}\t#{pane_dead}"]
        let out = runner.run(
            LightInvocation(
                argv: args,
                stdin: "",
                executable: true,
                fallback: false,
                summary: "tmux list-panes \(name)",
                loopback: true
            ),
            stdin: ""
        )
        guard out.status == 0 else { return nil }
        let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lines = trimmed.components(separatedBy: "\n")
        guard let firstLine = lines.first else { return nil }
        let fields = firstLine.components(separatedBy: "\t")
        guard fields.count >= 3,
              let pid = Int32(fields[0].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let command = fields[1].trimmingCharacters(in: .whitespaces)
        let dead = fields[2].trimmingCharacters(in: .whitespaces) == "1"
        return (pid: pid, command: command, dead: dead)
    }

    /// `tmux send-keys -t =NAME: -l -- TEXT`
    public func sendLiteral(_ name: String, _ text: String) -> Bool {
        let sendArgs = [tmux, "send-keys", "-t", "=\(name):", "-l", "--", text]
        let sendOut = runner.run(
            LightInvocation(
                argv: sendArgs,
                stdin: "",
                executable: true,
                fallback: false,
                summary: "tmux send-keys literal \(name)",
                loopback: true
            ),
            stdin: ""
        )
        return sendOut.status == 0
    }

    /// `tmux send-keys -t =NAME: -l -- TEXT` then separately `tmux send-keys -t =NAME: Enter`
    public func sendText(_ name: String, _ text: String) -> Bool {
        let sendArgs = [tmux, "send-keys", "-t", "=\(name):", "-l", "--", text]
        let sendOut = runner.run(
            LightInvocation(
                argv: sendArgs,
                stdin: "",
                executable: true,
                fallback: false,
                summary: "tmux send-keys text \(name)",
                loopback: true
            ),
            stdin: ""
        )
        guard sendOut.status == 0 else { return false }
        if enterDelay > 0 { Thread.sleep(forTimeInterval: enterDelay) }

        let enterArgs = [tmux, "send-keys", "-t", "=\(name):", "Enter"]
        let enterOut = runner.run(
            LightInvocation(
                argv: enterArgs,
                stdin: "",
                executable: true,
                fallback: false,
                summary: "tmux send-keys Enter \(name)",
                loopback: true
            ),
            stdin: ""
        )
        return enterOut.status == 0
    }

    /// `tmux send-keys -t =NAME: KEY`
    public func sendKey(_ name: String, _ key: String) -> Bool {
        let args = [tmux, "send-keys", "-t", "=\(name):", key]
        let out = runner.run(
            LightInvocation(
                argv: args,
                stdin: "",
                executable: true,
                fallback: false,
                summary: "tmux send-keys key \(name)",
                loopback: true
            ),
            stdin: ""
        )
        return out.status == 0
    }

    /// `tmux capture-pane -p -t =NAME:` (optionally `-S -N` for scrollback)
    public func capture(_ name: String, lines: Int? = nil) -> String? {
        var args = [tmux, "capture-pane", "-p", "-t", "=\(name):"]
        if let lines {
            let start = lines <= 0 ? "\(lines)" : "-\(lines)"
            args.append(contentsOf: ["-S", start])
        }
        let out = runner.run(
            LightInvocation(
                argv: args,
                stdin: "",
                executable: true,
                fallback: false,
                summary: "tmux capture-pane \(name)",
                loopback: true
            ),
            stdin: ""
        )
        guard out.status == 0 else { return nil }
        return out.stdout
    }

    /// `tmux kill-session -t =NAME` (used only by tests/cleanup commands, never automatically)
    public func kill(_ name: String) -> Bool {
        let args = [tmux, "kill-session", "-t", "=\(name)"]
        let out = runner.run(
            LightInvocation(
                argv: args,
                stdin: "",
                executable: true,
                fallback: false,
                summary: "tmux kill-session \(name)",
                loopback: true
            ),
            stdin: ""
        )
        return out.status == 0
    }

    /// `ps -o lstart= -p PID` trimmed; nil if ps fails/empty
    public func processStart(pid: Int32) -> String? {
        let args = ["ps", "-o", "lstart=", "-p", "\(pid)"]
        let out = runner.run(
            LightInvocation(
                argv: args,
                stdin: "",
                executable: true,
                fallback: false,
                summary: "ps lstart \(pid)",
                loopback: true
            ),
            stdin: ""
        )
        guard out.status == 0 else { return nil }
        let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Combine the above. Pid liveness: alive unless `ps` says the pid is gone (exit != 0 / empty output);
    /// if binding.agentStarted is set and differs from processStart(pid) -> agentAlive=false (pid reuse).
    public func liveness(_ binding: LightTmuxBinding) -> TmuxLiveness {
        let tmuxAlive = hasSession(binding.session)
        guard tmuxAlive else {
            return TmuxLiveness(
                tmuxAlive: false,
                agentAlive: false,
                panePID: nil,
                paneCommand: nil,
                paneDead: false
            )
        }

        let paneInfo = pane(binding.session)
        let panePID = paneInfo?.pid
        let paneCommand = paneInfo?.command
        let paneDead = paneInfo?.dead ?? false

        var agentAlive = false
        // The pane process is the agent (tmux execs argv directly). The recorded start time
        // guards only the recorded pid: a reused pid with another start time is not our agent.
        if !paneDead, let pid = panePID ?? binding.agentPID {
            if let start = processStart(pid: pid) {
                if pid == binding.agentPID, let expectedStart = binding.agentStarted {
                    agentAlive = (expectedStart == start)
                } else {
                    agentAlive = true
                }
            }
        }

        return TmuxLiveness(
            tmuxAlive: true,
            agentAlive: agentAlive,
            panePID: panePID,
            paneCommand: paneCommand,
            paneDead: paneDead
        )
    }
}

/// Valid tmux session names for members: `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$` (no dots/colons — tmux target syntax).
public enum TmuxNames {
    public static func isValid(_ s: String) -> Bool {
        guard s.count >= 1 && s.count <= 64 else { return false }
        func isAlphaNum(_ c: Character) -> Bool {
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
        }
        guard let first = s.first, isAlphaNum(first) else { return false }
        for c in s.dropFirst() {
            guard isAlphaNum(c) || c == "_" || c == "-" else { return false }
        }
        return true
    }

    public static func sessionName(forMember name: String, prefix: String = "pharos-") -> String {
        func isAlphaNum(_ c: Character) -> Bool {
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
        }
        func isAllowed(_ c: Character) -> Bool {
            isAlphaNum(c) || c == "_" || c == "-"
        }

        var sanitized = ""
        for c in "\(prefix)\(name)" {
            if isAllowed(c) {
                sanitized.append(c)
            } else {
                sanitized.append("-")
            }
        }

        // Must start with alphanumeric
        while let first = sanitized.first, !isAlphaNum(first) {
            sanitized.removeFirst()
        }

        if sanitized.isEmpty {
            sanitized = "pharos"
        }

        if sanitized.count > 64 {
            sanitized = String(sanitized.prefix(64))
        }

        return sanitized
    }
}
