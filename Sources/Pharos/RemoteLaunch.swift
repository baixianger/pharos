import Foundation

/// Phase E stub: full SSH/tmux RemoteLaunch depended on MeshSpawn / MeshCore.
/// Callers still compile; runtime returns a clear unsupported error.
enum RemoteLaunch {
    struct RemoteError: LocalizedError, CustomStringConvertible {
        enum Reason { case generic, paneUnavailable }
        let message: String
        var reason: Reason = .generic
        var description: String { message }
        var errorDescription: String? { message }
    }

    static func launch(
        project: Project,
        kind: AgentKind,
        host: String,
        yolo: Bool,
        issue: Int? = nil,
        brief: String? = nil,
        source: AuditLog.Source
    ) throws -> String {
        _ = (project, kind, host, yolo, issue, brief, source)
        throw RemoteError(
            message: "Remote agent launch moved to the Rust daemon; Swift RemoteLaunch was removed in Phase E."
        )
    }

    static func kill(session: String, host: String?) throws -> String {
        _ = (session, host)
        throw RemoteError(
            message: "Remote session kill moved to the Rust daemon; Swift RemoteLaunch was removed in Phase E."
        )
    }

    static func runningSessions(host: String) -> Set<String>? {
        _ = host
        return nil
    }
}
