import Foundation

/// Append-only audit trail for Pharos's own destructive / privileged operations.
///
/// The safety principle (see ROADMAP v1.1) is that destructive ops should be
/// "reversible/auditable, not just guarded by a UI prompt." Reversible deletes
/// go to the Trash; the operations that *aren't* a simple undo — yolo agent
/// launches (the agent can `rm` anything) and registry mutations driven headless
/// from the CLI — leave a line here instead, so there's always a trail.
///
/// One JSON object per line at `~/Library/Application Support/Pharos/audit.log`.
/// Best-effort: a failed write is dropped rather than thrown into the caller, so
/// logging never blocks or breaks an operation.
enum AuditLog {
    /// Which front door triggered the operation.
    enum Source: String { case ui, cli }

    /// Append one entry. `detail` is a short human-readable subject (project name,
    /// group name, launch target …).
    static func record(actor: Source, action: String, detail: String) {
        append(entry(actor: actor, action: action, detail: detail, at: Date()))
    }

    /// Pure formatter (testable): a single newline-terminated JSON line.
    static func entry(actor: Source, action: String, detail: String, at date: Date) -> String {
        let obj: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: date),
            "actor": actor.rawValue,
            "action": action,
            "detail": detail,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json + "\n"
    }

    /// Location of the audit log — always alongside the active registry, so it
    /// follows a `PHAROS_REGISTRY` override (and tests don't pollute the real log).
    static var logURL: URL {
        PharosCore.registryURL.deletingLastPathComponent().appendingPathComponent("audit.log")
    }

    private static func append(_ line: String) {
        guard !line.isEmpty, let data = line.data(using: .utf8) else { return }
        let url = logURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // First write — create the file.
            try? data.write(to: url, options: .atomic)
        }
    }
}
