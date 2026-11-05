import Foundation
import PharosMeshCore

public final class CLIMemberAgents: LightMemberAgents, @unchecked Sendable {
    public var lifecycle: CLIAgentLifecycle
    public var selfHost: LightSelfHost
    public var nodes: (any LightNodeRouting)?
    private let lock = NSLock()
    private var _notes: [String] = []

    public var notes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _notes
    }

    public init(
        lifecycle: CLIAgentLifecycle,
        selfHost: LightSelfHost = .fromEnvironment(),
        nodes: (any LightNodeRouting)? = nil
    ) {
        self.lifecycle = lifecycle
        self.selfHost = selfHost
        self.nodes = nodes
    }

    public static func parseResponse(_ stdout: String) -> LightNodeAgentResponse? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        for line in stdout.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
               let data = trimmed.data(using: .utf8),
               let resp = try? decoder.decode(LightNodeAgentResponse.self, from: data) {
                return resp
            }
        }
        if let start = stdout.firstIndex(of: "{"), let end = stdout.lastIndex(of: "}"), start <= end {
            let slice = String(stdout[start...end])
            if let data = slice.data(using: .utf8),
               let resp = try? decoder.decode(LightNodeAgentResponse.self, from: data) {
                return resp
            }
        }
        return nil
    }

    public func launch(
        name: String,
        app: String,
        cwd: String,
        host: String,
        model: String?,
        tmuxSession: String?,
        openingMessage: String?,
        project: String,
        mode: String? = nil
    ) throws -> LightMember {
        let effectiveMode = mode ?? "yolo"
        if !selfHost.matches(host) {
            guard let nodes else {
                throw CLIMemberAgentsError("launch on another host is not supported yet: run it on that machine")
            }

            let spec = LightNodeLaunchSpec(
                name: name,
                app: app,
                cwd: cwd,
                project: project,
                host: host,
                model: model,
                tmuxSession: tmuxSession,
                openingMessage: openingMessage,
                mode: effectiveMode
            )
            let request = LightNodeAgentRequest(action: "launch", launch: spec)
            let b64 = LightNodeExec.encode(request)

            guard let run = nodes.run(host, argv: ["node-agent", "--payload", b64], timeout: 240) else {
                let status = nodes.status(host)
                let msg = LightRelay.nodeOfflineMessage(lastSeen: status.lastSeen, now: Date())
                throw CLIMemberAgentsError("Pharos node \(host) is offline (\(msg))")
            }

            guard let resp = Self.parseResponse(run.stdout) else {
                throw CLIMemberAgentsError("invalid response from node \(host)")
            }

            guard resp.ok else {
                throw CLIMemberAgentsError(resp.error ?? "remote launch failed")
            }

            guard var launched = resp.member else {
                throw CLIMemberAgentsError("remote launch did not return a member")
            }
            launched.host = host

            var notes = resp.notes ?? []
            notes.append("via \(run.path.rawValue) on \(run.node)")
            lock.lock()
            _notes = notes
            lock.unlock()

            return launched
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
            host: host,
            mode: effectiveMode
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

    public func adopt(
        name: String,
        app: String,
        cwd: String,
        sessionID: String,
        host: String,
        model: String?,
        tmuxSession: String?,
        project: String,
        autoRevive: Bool,
        mode: String? = nil
    ) throws -> LightMember {
        let effectiveMode = mode ?? "yolo"
        if !selfHost.matches(host) {
            guard let nodes else {
                throw CLIMemberAgentsError("adopt on another host is not supported yet: run it on that machine")
            }

            let spec = LightNodeAdoptSpec(
                name: name,
                app: app,
                cwd: cwd,
                sessionID: sessionID,
                project: project,
                host: host,
                model: model,
                tmuxSession: tmuxSession,
                autoRevive: autoRevive,
                mode: effectiveMode
            )
            let request = LightNodeAgentRequest(action: "adopt", adopt: spec)
            let b64 = LightNodeExec.encode(request)

            guard let run = nodes.run(host, argv: ["node-agent", "--payload", b64], timeout: 240) else {
                let status = nodes.status(host)
                let msg = LightRelay.nodeOfflineMessage(lastSeen: status.lastSeen, now: Date())
                throw CLIMemberAgentsError("Pharos node \(host) is offline (\(msg))")
            }

            guard let resp = Self.parseResponse(run.stdout) else {
                throw CLIMemberAgentsError("invalid response from node \(host)")
            }

            guard resp.ok else {
                throw CLIMemberAgentsError(resp.error ?? "remote adopt failed")
            }

            guard var adopted = resp.member else {
                throw CLIMemberAgentsError("remote adopt did not return a member")
            }
            adopted.host = host

            var notes = resp.notes ?? []
            notes.append("via \(run.path.rawValue) on \(run.node)")
            lock.lock()
            _notes = notes
            lock.unlock()

            return adopted
        }

        let adoptReq = CLIAgentAdoptRequest(
            name: name,
            app: app,
            cwd: cwd,
            sessionID: sessionID,
            host: host,
            model: model,
            tmuxSession: tmuxSession,
            project: project,
            autoRevive: autoRevive,
            mode: effectiveMode
        )
        let member = try lifecycle.adopt(request: adoptReq)
        lock.lock()
        _notes = []
        lock.unlock()
        return member
    }

    public func revive(_ member: LightMember) throws -> LightTmuxBinding {
        if !selfHost.matches(member.host) {
            guard let nodes else {
                throw CLIMemberAgentsError("revive on another host is not supported yet: run it on that machine")
            }

            let request = LightNodeAgentRequest(action: "revive", member: member)
            let b64 = LightNodeExec.encode(request)

            guard let run = nodes.run(member.host, argv: ["node-agent", "--payload", b64], timeout: 240) else {
                let status = nodes.status(member.host)
                let msg = LightRelay.nodeOfflineMessage(lastSeen: status.lastSeen, now: Date())
                throw CLIMemberAgentsError("Pharos node \(member.host) is offline (\(msg))")
            }

            guard let resp = Self.parseResponse(run.stdout) else {
                throw CLIMemberAgentsError("invalid response from node \(member.host)")
            }

            guard resp.ok else {
                throw CLIMemberAgentsError(resp.error ?? "remote revive failed")
            }

            guard let binding = resp.binding else {
                throw CLIMemberAgentsError("remote revive did not return a binding")
            }

            var notes = resp.notes ?? []
            notes.append("via \(run.path.rawValue) on \(run.node)")
            lock.lock()
            _notes = notes
            lock.unlock()

            return binding
        }

        return try lifecycle.revive(member: member)
    }

    public func stop(_ member: LightMember, force: Bool) throws -> LightTmuxBinding {
        if selfHost.matches(member.host) {
            let res = try lifecycle.stop(member: member, force: force)
            lock.lock()
            _notes = ["stop: \(res.how)"]
            lock.unlock()
            return res.binding
        }

        guard let nodes else {
            throw CLIMemberAgentsError("stop on another host is not supported yet: run it on that machine")
        }

        let request = LightNodeAgentRequest(action: "stop", member: member, force: force)
        let b64 = LightNodeExec.encode(request)

        guard let run = nodes.run(member.host, argv: ["node-agent", "--payload", b64], timeout: 60) else {
            let status = nodes.status(member.host)
            let msg = LightRelay.nodeOfflineMessage(lastSeen: status.lastSeen, now: Date())
            throw CLIMemberAgentsError("Pharos node \(member.host) is offline (\(msg))")
        }

        guard let resp = Self.parseResponse(run.stdout) else {
            throw CLIMemberAgentsError("invalid response from node \(member.host)")
        }

        guard resp.ok else {
            throw CLIMemberAgentsError(resp.error ?? "remote stop failed")
        }

        guard let binding = resp.binding else {
            throw CLIMemberAgentsError("remote stop did not return a binding")
        }

        var notes = resp.notes ?? []
        notes.append("via \(run.path.rawValue) on \(run.node)")
        lock.lock()
        _notes = notes
        lock.unlock()

        return binding
    }

    public func switchModel(_ member: LightMember, model: String, force: Bool) throws -> LightTmuxBinding {
        if selfHost.matches(member.host) {
            let binding = try lifecycle.switchModel(member: member, model: model, force: force)
            lock.lock()
            _notes = ["switched to model \(model)"]
            lock.unlock()
            return binding
        }

        guard let nodes else {
            throw CLIMemberAgentsError("switch model on another host is not supported yet: run it on that machine")
        }

        let request = LightNodeAgentRequest(action: "model", member: member, force: force, model: model)
        let b64 = LightNodeExec.encode(request)

        guard let run = nodes.run(member.host, argv: ["node-agent", "--payload", b64], timeout: 60) else {
            let status = nodes.status(member.host)
            let msg = LightRelay.nodeOfflineMessage(lastSeen: status.lastSeen, now: Date())
            throw CLIMemberAgentsError("Pharos node \(member.host) is offline (\(msg))")
        }

        guard let resp = Self.parseResponse(run.stdout) else {
            throw CLIMemberAgentsError("invalid response from node \(member.host)")
        }

        guard resp.ok else {
            throw CLIMemberAgentsError(resp.error ?? "remote switch model failed")
        }

        guard let binding = resp.binding else {
            throw CLIMemberAgentsError("remote switch model did not return a binding")
        }

        var notes = resp.notes ?? []
        notes.append("via \(run.path.rawValue) on \(run.node)")
        lock.lock()
        _notes = notes
        lock.unlock()

        return binding
    }

    public func switchMode(_ member: LightMember, mode: String, force: Bool) throws -> LightTmuxBinding {
        if selfHost.matches(member.host) {
            let binding = try lifecycle.switchMode(member: member, mode: mode, force: force)
            lock.lock()
            _notes = ["switched to mode \(mode)"]
            lock.unlock()
            return binding
        }

        guard let nodes else {
            throw CLIMemberAgentsError("switch mode on another host is not supported yet: run it on that machine")
        }

        let request = LightNodeAgentRequest(action: "mode", member: member, force: force, mode: mode)
        let b64 = LightNodeExec.encode(request)

        guard let run = nodes.run(member.host, argv: ["node-agent", "--payload", b64], timeout: 60) else {
            let status = nodes.status(member.host)
            let msg = LightRelay.nodeOfflineMessage(lastSeen: status.lastSeen, now: Date())
            throw CLIMemberAgentsError("Pharos node \(member.host) is offline (\(msg))")
        }

        guard let resp = Self.parseResponse(run.stdout) else {
            throw CLIMemberAgentsError("invalid response from node \(member.host)")
        }

        guard resp.ok else {
            throw CLIMemberAgentsError(resp.error ?? "remote switch mode failed")
        }

        guard let binding = resp.binding else {
            throw CLIMemberAgentsError("remote switch mode did not return a binding")
        }

        var notes = resp.notes ?? []
        notes.append("via \(run.path.rawValue) on \(run.node)")
        lock.lock()
        _notes = notes
        lock.unlock()

        return binding
    }

    public func modelInfo(_ member: LightMember) -> LightMemberModelInfo? {
        let currentModel = member.tmux?.model ?? "default"
        guard let descriptor = CLIAgentDescriptor.named(member.app, env: lifecycle.env) else {
            return nil
        }
        let available = descriptor.availableModels
        var quotaMap: [String: String] = [:]
        for m in available {
            if let until = lifecycle.quota.exhausted(app: member.app, model: m) {
                quotaMap[m] = ISO8601DateFormatter().string(from: until)
            }
        }
        return LightMemberModelInfo(
            member: member.name,
            app: member.app,
            current: currentModel,
            available: available,
            quota: quotaMap
        )
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
