import Foundation
import PharosMeshCore

public final class CLIMemberAgents: LightMemberAgents, @unchecked Sendable {
    public var lifecycle: CLIAgentLifecycle
    public var selfHost: LightSelfHost
    private let lock = NSLock()
    private var _notes: [String] = []

    public var notes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _notes
    }

    public init(
        lifecycle: CLIAgentLifecycle,
        selfHost: LightSelfHost = .fromEnvironment()
    ) {
        self.lifecycle = lifecycle
        self.selfHost = selfHost
    }

    public func launch(
        name: String,
        app: String,
        cwd: String,
        host: String,
        model: String?,
        tmuxSession: String?,
        openingMessage: String?,
        project: String
    ) throws -> LightMember {
        guard selfHost.matches(host) else {
            throw CLIMemberAgentsError("launch on another host is not supported yet: run it on that machine")
        }

        guard let descriptor = CLIAgentDescriptor.named(app, env: lifecycle.env) else {
            throw CLIAgentLifecycleError.invalid("unsupported app: \(app)")
        }

        let request = CLIAgentLaunchRequest(
            name: name,
            app: app,
            cwd: cwd,
            model: model,
            sessionName: tmuxSession,
            openingMessage: openingMessage,
            host: host
        )

        let result = try lifecycle.launch(request)
        lock.lock()
        _notes = result.notes
        lock.unlock()

        return LightMember(
            name: name,
            host: host,
            app: app,
            project: project,
            sessionID: result.sessionID,
            routes: descriptor.routes,
            tmux: result.binding
        )
    }

    public func revive(_ member: LightMember) throws -> LightTmuxBinding {
        guard selfHost.matches(member.host) else {
            throw CLIMemberAgentsError("revive on another host is not supported yet: run it on that machine")
        }
        return try lifecycle.revive(member: member)
    }

    public func status(_ member: LightMember) -> LightMemberRuntimeStatus? {
        guard member.tmux != nil else { return nil }
        guard selfHost.matches(member.host) else { return nil }

        let st = lifecycle.status(member: member)
        return LightMemberRuntimeStatus(
            tmux: st.tmux,
            live: st.live,
            activity: st.activity.rawValue,
            detail: st.detail
        )
    }
}

public struct CLIMemberAgentsError: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
