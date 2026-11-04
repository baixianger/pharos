import Foundation
import PharosMeshCore

// Node-to-node routing for the lightweight tier.
//
// A request for another machine is run by that machine's Pharos node, never by
// the caller. Route choice is internal: the Pharos mesh first (a `light` node
// command through the Broker), SSH as the backup when the node is not on the
// mesh (the request runs there under that machine's own `pharos`), and when
// both fail the caller queues on the Broker's per-node inbox. Results name the
// path actually used.

public enum LightNodePath: String, Sendable, Equatable {
    case mesh
    case ssh
}

public struct LightNodeRun: Equatable, Sendable {
    public var path: LightNodePath
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var node: String

    public init(path: LightNodePath, status: Int32, stdout: String, stderr: String, node: String) {
        self.path = path
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.node = node
    }
}

public protocol LightNodeRouting: LightNodeLiveness, Sendable {
    /// Roster plus aliases; nil when the Broker is not reachable from here.
    func directory() -> LightHostDirectory?
    /// Canonical node name for a `--host` label (alias, node name, id, IP).
    func canonical(_ label: String) -> String
    func status(_ label: String) -> LightNodeStatus
    /// Run `pharos <argv>` on that node: mesh, then SSH. Nil when neither reached it.
    func run(_ label: String, argv: [String], timeout: TimeInterval) -> LightNodeRun?
    /// The node on the Broker's machine (owner of the light ledger), when known.
    func hubName() -> String?
}

extension LightNodeRouting {
    public func canonical(_ label: String) -> String {
        (directory() ?? LightHostDirectory(nodes: [], config: LightHostsConfig())).canonical(label)
    }

    public func status(_ label: String) -> LightNodeStatus {
        nodeStatus(label) ?? LightNodeStatus(host: label, online: false, lastSeen: nil)
    }

    public func hubName() -> String? { directory()?.hub?.name }

    public func nodeStatus(_ host: String) -> LightNodeStatus? {
        guard let directory = directory() else { return nil }
        guard let node = directory.node(for: host) else { return nil }
        return LightNodeStatus(host: node.name, online: node.online(at: Date()), lastSeen: node.lastSeen)
    }
}

/// The Broker calls the router needs. A seam so tests run without sockets.
public protocol LightBrokerLink: Sendable {
    func roster() -> [LightMeshNode]?
    func enqueue(nodeID: String, payload: MeshLightCommandPayload, deadline: Date, key: String) -> String?
    func command(id: String) -> MeshNodeCommand?
    func cancel(id: String, nodeID: String)
}

/// No Broker: every route is SSH or queue.
public struct NoBrokerLink: LightBrokerLink {
    public init() {}
    public func roster() -> [LightMeshNode]? { nil }
    public func enqueue(nodeID: String, payload: MeshLightCommandPayload, deadline: Date, key: String) -> String? { nil }
    public func command(id: String) -> MeshNodeCommand? { nil }
    public func cancel(id: String, nodeID: String) {}
}

/// The real Broker. `endpoint` dials a TCP Broker (`PHAROS_MESH_TCP`); nil talks to
/// the Broker already serving this machine's socket (or the saved route) and never spawns one.
public struct MeshBrokerLink: LightBrokerLink {
    public var endpoint: String?

    public init(endpoint: String? = nil) { self.endpoint = endpoint }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> MeshBrokerLink {
        let value = env["PHAROS_MESH_TCP"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return MeshBrokerLink(endpoint: value.isEmpty ? nil : value)
    }

    func send(_ request: MeshRequest) -> MeshResponse {
        if let endpoint { return MeshClient.send(request, to: endpoint, timeoutSec: 4) }
        return MeshClient.sendIfUp(request) ?? .fail("no Broker on this machine")
    }

    public func roster() -> [LightMeshNode]? {
        let response = send(MeshRequest(cmd: "node-roster"))
        guard response.ok else { return nil }
        return (response.nodes ?? []).map(LightMeshNode.init)
    }

    public func enqueue(nodeID: String, payload: MeshLightCommandPayload, deadline: Date, key: String) -> String? {
        guard let data = try? JSONEncoder().encode(payload), let text = String(data: data, encoding: .utf8) else { return nil }
        var request = MeshRequest(cmd: "node-command-enqueue", payload: text, nodeID: nodeID,
                                  action: MeshNodeCommandAction.light.rawValue, idempotencyKey: key,
                                  deadline: deadline.timeIntervalSince1970)
        request.maxAttempts = 3
        let response = send(request)
        guard response.ok else { return nil }
        return response.command?.id
    }

    public func command(id: String) -> MeshNodeCommand? {
        let response = send(MeshRequest(cmd: "node-command-get", commandID: id))
        return response.ok ? response.command : nil
    }

    public func cancel(id: String, nodeID: String) {
        _ = send(MeshRequest(cmd: "node-command-update", state: MeshNodeCommandState.canceled.rawValue,
                             payload: "not claimed by the node in time; caller used the backup route",
                             nodeID: nodeID, commandID: id))
    }
}

/// SSH backup: the request runs under the target machine's own `pharos`.
public struct LightSSHRoute: Sendable {
    public var runner: any LightProcessRunning
    /// Shell text for the target's `pharos` (`LightAppBins.remotePharosShell`).
    public var remotePharos: String
    public var connectTimeout: Int

    public init(runner: any LightProcessRunning, remotePharos: String = "pharos", connectTimeout: Int = 6) {
        self.runner = runner
        self.remotePharos = remotePharos
        self.connectTimeout = connectTimeout
    }

    public static func command(remotePharos: String, argv: [String]) -> String {
        // The target runs the request itself: no second hand-off to its node.
        (["PHAROS_LIGHT_DIRECT=1", remotePharos] + argv.map(SSHLightReplyForwarder.shellQuote)).joined(separator: " ")
    }

    public func run(destination: String, argv: [String]) -> LightProcessOutput {
        runner.run(LightInvocation(
            argv: ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)", "--", destination,
                   Self.command(remotePharos: remotePharos, argv: argv)],
            stdin: "", executable: true, fallback: false,
            summary: "backup route: run pharos \(argv.first ?? "") on the target node over SSH", loopback: false
        ), stdin: "")
    }
}

public final class LightMeshRouter: LightNodeRouting, @unchecked Sendable {
    public let link: any LightBrokerLink
    public let hosts: LightHostsConfig
    public let ssh: LightSSHRoute?
    /// Extra SSH destinations by node name (e.g. `PHAROS_LIGHT_SSH_HOST` for the hub).
    public let sshOverrides: [String: String]
    public let claimTimeout: TimeInterval
    private let now: @Sendable () -> Date
    private let pause: @Sendable (TimeInterval) -> Void
    private let lock = NSLock()
    private var cached: (at: Date, value: LightHostDirectory?)?

    public init(link: any LightBrokerLink, hosts: LightHostsConfig = LightHostsConfig(), ssh: LightSSHRoute?,
                sshOverrides: [String: String] = [:], claimTimeout: TimeInterval = 12,
                now: @escaping @Sendable () -> Date = { Date() },
                pause: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.link = link
        self.hosts = hosts
        self.ssh = ssh
        self.sshOverrides = sshOverrides
        self.claimTimeout = claimTimeout
        self.now = now
        self.pause = pause
    }

    public func directory() -> LightHostDirectory? {
        lock.lock()
        defer { lock.unlock() }
        if let cached, now().timeIntervalSince(cached.at) < 5 { return cached.value }
        let value = link.roster().map { LightHostDirectory(nodes: $0, config: hosts) }
        cached = (now(), value)
        return value
    }

    private var offlineDirectory: LightHostDirectory {
        directory() ?? LightHostDirectory(nodes: [], config: hosts)
    }

    public func run(_ label: String, argv: [String], timeout: TimeInterval) -> LightNodeRun? {
        let directory = offlineDirectory
        let node = directory.node(for: label)
        let name = node?.name ?? directory.canonical(label)
        if let node, node.online(at: now()), let done = meshRun(node, argv: argv, timeout: timeout) {
            return done
        }
        guard let ssh else { return nil }
        let destination = sshOverrides[name] ?? directory.sshDestination(for: label)
        guard let destination, !destination.isEmpty else { return nil }
        let output = ssh.run(destination: destination, argv: argv)
        // 255 is ssh's own failure (no route, refused, auth): the node was not reached.
        if output.status == 255 { return nil }
        return LightNodeRun(path: .ssh, status: output.status, stdout: output.stdout, stderr: output.stderr, node: name)
    }

    private func meshRun(_ node: LightMeshNode, argv: [String], timeout: TimeInterval) -> LightNodeRun? {
        let started = now()
        let payload = MeshLightCommandPayload(argv: argv, timeoutSec: timeout)
        guard let id = link.enqueue(nodeID: node.id, payload: payload,
                                    deadline: started.addingTimeInterval(timeout + 60),
                                    key: "light-" + UUID().uuidString.lowercased()) else { return nil }
        var claimed = false
        while true {
            if let command = link.command(id: id) {
                if command.state != .queued { claimed = true }
                if command.state.isTerminal {
                    if let text = command.result, let data = text.data(using: .utf8),
                       let result = try? JSONDecoder().decode(MeshLightCommandResult.self, from: data) {
                        return LightNodeRun(path: .mesh, status: result.exitCode, stdout: result.stdout,
                                            stderr: result.stderr, node: node.name)
                    }
                    if command.state == .canceled || command.state == .expired, !claimed { return nil }
                    return LightNodeRun(path: .mesh, status: 1, stdout: "", stderr: command.result ?? command.state.rawValue,
                                        node: node.name)
                }
            }
            let elapsed = now().timeIntervalSince(started)
            if !claimed, elapsed >= claimTimeout {
                link.cancel(id: id, nodeID: node.id)
                // A claim may have raced the cancel; prefer the node's answer when it has one.
                if let command = link.command(id: id), command.state != .canceled, command.state != .queued {
                    claimed = true
                    continue
                }
                return nil
            }
            if elapsed >= timeout {
                return LightNodeRun(path: .mesh, status: 124, stdout: "",
                                    stderr: "Pharos node \(node.name) took the request (\(id)) and is still running it",
                                    node: node.name)
            }
            pause(0.25)
        }
    }
}
