import Foundation
import PharosMeshCore

// needs_human sources for the light tier. Hooks push (`pharos attention report`,
// written by the per-app adapters in achat); this file is the poll side, for apps
// that raise no approval event Pharos can hook. Every source only observes: none
// answers, approves, or denies a prompt.

public protocol HumanAttentionSource: Sendable {
    /// Normalized observations for `members`. A member the source cannot see is left out.
    func poll(members: [LightMember]) -> [LightAttentionReport]
}

/// Combines multiple attention poll sources into one pass.
public struct CombinedAttentionSource: HumanAttentionSource {
    public var sources: [any HumanAttentionSource]

    public init(sources: [any HumanAttentionSource]) {
        self.sources = sources
    }

    public func poll(members: [LightMember]) -> [LightAttentionReport] {
        sources.flatMap { $0.poll(members: members) }
    }
}

/// Reads `achat <app> pending` for members on this machine. Read-only: dsh from
/// its session log (`--via files`), Antigravity from the open window over CDP on
/// 127.0.0.1 without navigating it, Cursor from its own pending surface.
public struct AchatPendingAttentionSource: HumanAttentionSource {
    public var runner: any LightProcessRunning
    public var achat: String
    /// Apps polled here. Codex and Claude Code report through their hooks instead.
    public var apps: Set<String>
    public var isLocal: @Sendable (LightMember) -> Bool
    /// Host label written into the reports.
    public var hostLabel: String
    /// At most this many `achat` runs per pass (a shared window read counts once).
    public var limit: Int

    public static let defaultApps: Set<String> = ["ag", "dsh", "cursor"]

    public init(runner: any LightProcessRunning, achat: String, apps: Set<String> = AchatPendingAttentionSource.defaultApps,
                isLocal: @escaping @Sendable (LightMember) -> Bool, hostLabel: String, limit: Int = 4) {
        self.runner = runner
        self.achat = achat
        self.apps = apps
        self.isLocal = isLocal
        self.hostLabel = hostLabel
        self.limit = limit
    }

    public func poll(members: [LightMember]) -> [LightAttentionReport] {
        var reports: [LightAttentionReport] = []
        var windowRead: [String: String] = [:]
        var runs = 0
        for member in members where apps.contains(member.app) && isLocal(member) {
            let argv = Self.pendingArgv(bin: achat, member: member)
            let key = argv.joined(separator: " ")
            let stdout: String
            if let cached = windowRead[key] {
                stdout = cached
            } else {
                guard runs < max(0, limit) else { continue }
                runs += 1
                let output = runner.run(LightInvocation(argv: argv, stdin: "", executable: true, fallback: false,
                                                        summary: "achat \(member.app) pending", loopback: true), stdin: "")
                guard output.status == 0 else { continue }
                stdout = output.stdout
                windowRead[key] = stdout
            }
            if var report = Self.interpret(member: member, stdout: stdout) {
                report.host = hostLabel
                reports.append(report)
            }
        }
        return reports
    }

    /// Antigravity is read without `--session` so the window is never switched;
    /// the answer counts only when the open conversation is the member's.
    public static func pendingArgv(bin: String, member: LightMember) -> [String] {
        switch member.app {
        case "ag": return [bin, "ag", "pending", "--json"]
        case "dsh": return [bin, "dsh", "pending", "--via", "files", "--session", member.sessionID, "--json"]
        default: return [bin, member.app, "pending", "--session", member.sessionID, "--json"]
        }
    }

    /// `needs_human` when an approval prompt is open, `clear` when none is, nil when
    /// the output says nothing about this member's session.
    public static func interpret(member: LightMember, stdout: String) -> LightAttentionReport? {
        guard let object = LightSessionService.extractJSON(stdout), (object["ok"] as? Bool) != false,
              let rows = object["pending"] as? [[String: Any]] else { return nil }
        if let open = (object["conversation"] as? String) ?? (object["sessionId"] as? String) ?? (object["chatId"] as? String),
           !open.isEmpty, open != member.sessionID {
            return nil
        }
        if member.app == "ag", (object["conversation"] as? String) == nil { return nil }
        // Only approval prompts count; a dsh question card is the agent asking, not a permission.
        let approvals = rows.filter { row in
            guard let kind = row["kind"] as? String else { return true }
            return kind == "approval"
        }
        guard let first = approvals.first else {
            return LightAttentionReport(state: .clear, sessionID: member.sessionID, app: member.app, source: "poll")
        }
        let what = [first["tool"], first["reason"], first["text"]].compactMap { $0 as? String }
            .filter { !$0.isEmpty }.joined(separator: ": ")
        return LightAttentionReport(state: .needsHuman, what: LightAttention.clip(what), sessionID: member.sessionID,
                                    app: member.app, source: "poll")
    }
}
