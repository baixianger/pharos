import Foundation
import PharosMeshCore

public struct CLIAgentEnvironment: Sendable {
    public var tmux: TmuxController
    public var quota: CLIQuotaBook
    public var cursors: CLIReplyCursorBook
    public var daemon: @Sendable () -> CodexDaemonClient?
    public var lifecycle: CLIAgentLifecycle
    public var memberAgents: CLIMemberAgents
    public var driver: CLIAgentDriver
    public var attentionSource: CLIAgentAttentionSource

    public init(
        tmux: TmuxController,
        quota: CLIQuotaBook,
        cursors: CLIReplyCursorBook,
        daemon: @escaping @Sendable () -> CodexDaemonClient?,
        lifecycle: CLIAgentLifecycle,
        memberAgents: CLIMemberAgents,
        driver: CLIAgentDriver,
        attentionSource: CLIAgentAttentionSource
    ) {
        self.tmux = tmux
        self.quota = quota
        self.cursors = cursors
        self.daemon = daemon
        self.lifecycle = lifecycle
        self.memberAgents = memberAgents
        self.driver = driver
        self.attentionSource = attentionSource
    }

    public static func resolveTmuxBin(env: [String: String]) -> String {
        if let bin = env["PHAROS_TMUX_BIN"], !bin.isEmpty { return bin }
        for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "tmux"
    }

    public static func make(
        env: [String: String] = ProcessInfo.processInfo.environment,
        storeURL: URL = LightRelay.defaultStoreURL(),
        runner: any LightProcessRunning = FoundationLightProcessRunner(),
        nodes: (any LightNodeRouting)? = nil
    ) -> CLIAgentEnvironment? {
        guard env["PHAROS_LIGHT_LIVE"] == "1" else { return nil }

        let tmuxBin = resolveTmuxBin(env: env)
        let tmux = TmuxController(tmux: tmuxBin, runner: runner)
        let quota = CLIQuotaBook(store: storeURL.appendingPathComponent("cli-quota.json"))
        let cursors = CLIReplyCursorBook(store: storeURL.appendingPathComponent("cli-reply-cursors.json"))

        let daemonClosure: @Sendable () -> CodexDaemonClient? = {
            let socket = CodexDaemonClient.socketPath(env: env)
            return FileManager.default.fileExists(atPath: socket) ? CodexDaemonClient(socketPath: socket) : nil
        }

        let lifecycle = CLIAgentLifecycle(
            tmux: tmux,
            runner: runner,
            env: env,
            daemon: daemonClosure,
            quota: quota
        )

        let selfHost = LightSelfHost.fromEnvironment(env)
        let memberAgents = CLIMemberAgents(lifecycle: lifecycle, selfHost: selfHost, nodes: nodes)

        let driver = CLIAgentDriver(
            tmux: tmux,
            daemon: daemonClosure,
            quota: quota,
            cursors: cursors,
            env: env
        )

        let hostLabel = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init)?.lowercased() ?? "local"
        let attentionSource = CLIAgentAttentionSource(
            driver: driver,
            isLocal: { selfHost.matches($0.host) },
            hostLabel: hostLabel
        )

        return CLIAgentEnvironment(
            tmux: tmux,
            quota: quota,
            cursors: cursors,
            daemon: daemonClosure,
            lifecycle: lifecycle,
            memberAgents: memberAgents,
            driver: driver,
            attentionSource: attentionSource
        )
    }
}
