import Foundation
import PharosMeshCore

public struct CLIAgentDescriptor: Sendable, Equatable {
    public var app: String
    public var displayName: String
    public var binaryEnv: String
    public var binaryCandidates: [String]
    public var processNames: [String]
    public var appDataDir: String
    public var modelChain: [String]
    public var routes: [LightRoute]
    public var openingMessageRequired: Bool
    public var exitCommand: String

    public init(
        app: String,
        displayName: String,
        binaryEnv: String,
        binaryCandidates: [String],
        processNames: [String],
        appDataDir: String,
        modelChain: [String],
        routes: [LightRoute],
        openingMessageRequired: Bool,
        exitCommand: String = ""
    ) {
        self.app = app
        self.displayName = displayName
        self.binaryEnv = binaryEnv
        self.binaryCandidates = binaryCandidates
        self.processNames = processNames
        self.appDataDir = appDataDir
        self.modelChain = modelChain
        self.routes = routes
        self.openingMessageRequired = openingMessageRequired
        self.exitCommand = exitCommand
    }

    /// argv for a fresh session: codex: [bin, "--no-alt-screen"] (+ ["-m", model]); agy: [bin] (+ ["--model", model])
    public func launchArgv(bin: String, model: String?) -> [String] {
        if app == "codex" {
            var args = [bin, "--no-alt-screen"]
            if let model, !model.isEmpty {
                args.append(contentsOf: ["-m", model])
            }
            return args
        } else {
            var args = [bin]
            if let model, !model.isEmpty {
                args.append(contentsOf: ["--model", model])
            }
            return args
        }
    }

    /// argv for resuming `sessionID`: codex: [bin, "resume", sessionID, "--no-alt-screen"] (+ -m); agy: [bin, "--conversation", sessionID] (+ --model)
    public func resumeArgv(bin: String, sessionID: String, model: String?) -> [String] {
        if app == "codex" {
            var args = [bin, "resume", sessionID, "--no-alt-screen"]
            if let model, !model.isEmpty {
                args.append(contentsOf: ["-m", model])
            }
            return args
        } else {
            var args = [bin, "--conversation", sessionID]
            if let model, !model.isEmpty {
                args.append(contentsOf: ["--model", model])
            }
            return args
        }
    }

    /// env value, else first executable candidate (expand ~ with HOME), else app name
    public func resolveBinary(env: [String: String], isExecutable: (String) -> Bool) -> String {
        if let val = env[binaryEnv], !val.trimmingCharacters(in: .whitespaces).isEmpty {
            return val
        }
        let home = env["HOME"] ?? NSHomeDirectory()
        for candidate in binaryCandidates {
            let expanded: String
            if candidate.hasPrefix("~/") {
                expanded = home + "/" + candidate.dropFirst(2)
            } else if candidate == "~" {
                expanded = home
            } else {
                expanded = candidate
            }
            if isExecutable(expanded) {
                return expanded
            }
        }
        return app
    }

    private func expandedAppData(home: String) -> String {
        if appDataDir.hasPrefix("~/") {
            return home + "/" + appDataDir.dropFirst(2)
        } else if appDataDir == "~" {
            return home
        } else {
            return appDataDir
        }
    }

    /// agy: <appData>/brain/<id>/.system_generated/logs/transcript.jsonl ; codex: nil (read via daemon)
    public func transcriptPath(sessionID: String, home: String) -> String? {
        if app == "agy" {
            let dir = expandedAppData(home: home)
            return "\(dir)/brain/\(sessionID)/.system_generated/logs/transcript.jsonl"
        }
        return nil
    }

    /// agy: <appData>/presence/<id>.lock (held by the TUI that owns the conversation); codex: <appData>/thread-writer-locks/<id>.lock
    public func lockPath(sessionID: String, home: String) -> String {
        let dir = expandedAppData(home: home)
        if app == "agy" {
            return "\(dir)/presence/\(sessionID).lock"
        } else if app == "codex" {
            return "\(dir)/thread-writer-locks/\(sessionID).lock"
        } else {
            return "\(dir)/locks/\(sessionID).lock"
        }
    }

    public static let codex = CLIAgentDescriptor(
        app: "codex",
        displayName: "Codex",
        binaryEnv: "PHAROS_CODEX_TUI_BIN",
        binaryCandidates: [
            "/opt/homebrew/bin/codex",
            "~/.local/bin/codex",
            "/usr/local/bin/codex"
        ],
        processNames: ["codex"],
        appDataDir: "~/.codex",
        modelChain: [],
        routes: [
            LightRoute(
                id: "daemon",
                access: .write,
                fallback: false,
                summary: "codex shared app-server daemon: thread/queue/add into the member's TUI thread; read via thread/turns/list. Never answers approvals."
            ),
            LightRoute(
                id: "tui",
                access: .write,
                fallback: true,
                summary: "tmux send-keys into the member's tmux session (idle check first); replies from the transcript (agy) or the daemon/rollout (codex)."
            )
        ],
        openingMessageRequired: false,
        exitCommand: "/quit"
    )

    public static func agy(env: [String: String]) -> CLIAgentDescriptor {
        CLIAgentDescriptor(
            app: "agy",
            displayName: "Antigravity CLI",
            binaryEnv: "PHAROS_AGY_BIN",
            binaryCandidates: [
                "/opt/homebrew/bin/agy",
                "~/.local/bin/agy"
            ],
            processNames: ["agy"],
            appDataDir: "~/.gemini/antigravity-cli",
            modelChain: CLIModelChains.agy(env: env),
            routes: [
                LightRoute(
                    id: "tui",
                    access: .write,
                    fallback: false,
                    summary: "tmux send-keys into the member's tmux session (idle check first); replies from the transcript (agy) or the daemon/rollout (codex)."
                )
            ],
            openingMessageRequired: true,
            exitCommand: "/exit"
        )
    }

    public static func named(_ app: String, env: [String: String]) -> CLIAgentDescriptor? {
        switch app.lowercased() {
        case "codex":
            return .codex
        case "agy", "antigravity":
            return .agy(env: env)
        default:
            return nil
        }
    }
}
