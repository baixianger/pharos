import Foundation
import PharosMeshCore
#if canImport(Darwin)
import Darwin
#endif

public struct PharosRuntimeStatus: Equatable, Sendable {
    public let configuration: PharosRuntimeConfiguration
    public let effectiveBrokerEndpoint: String
    public let nodeRunning: Bool
    public let brokerRunning: Bool
}

/// The sole application service that translates a device role into persistent
/// macOS services. UI and CLI call this type rather than managing daemons.
public struct PharosRuntimeCoordinator {
    private static let nodeLabel = "me.pai.pharos.mesh-node"
    private static let brokerLabel = "me.pai.pharos.mesh-broker"

    private let store: PharosRuntimeConfigurationStore

    public init(store: PharosRuntimeConfigurationStore = .init()) {
        self.store = store
    }

    @discardableResult
    public func apply(_ requested: PharosRuntimeConfiguration) throws -> PharosRuntimeStatus {
        let configuration = try requested.validated()
        let helper = try helperPath()
        let previous = store.load()
        preserveCurrentCredential(for: previous)

        switch configuration.role {
        case .node:
            let endpoint = configuration.validRemoteBrokerEndpoint!
            try restoreCredential(for: endpoint, previous: previous)
            try requireBroker(at: endpoint)
            try ensureNode(helper: helper, endpoint: endpoint)
            try uninstallBroker()
            activateRoute(endpoint)
            store.save(configuration)
            return status(configuration: configuration, endpoint: endpoint)

        case .broker:
            let endpoint = try localBrokerEndpoint()
            try installBroker(helper: helper, endpoint: endpoint)
            try requireBroker(at: endpoint, attempts: 20)
            preserveCurrentCredential(for: endpoint)
            try ensureNode(helper: helper, endpoint: endpoint)
            activateRoute(endpoint)
            store.save(configuration)
            return status(configuration: configuration, endpoint: endpoint)
        }
    }

    public func reconcileSavedConfiguration() throws -> PharosRuntimeStatus {
        try apply(store.load())
    }

    /// Adopt a credential immediately returned by an explicit pairing flow.
    public func recordCurrentCredential(for endpoint: String) throws {
        guard meshSplitHostPort(endpoint) != nil, MeshPaths.controlToken != nil else {
            throw PharosRuntimeError.missingBrokerCredential(endpoint)
        }
        preserveCurrentCredential(for: endpoint)
    }

    public func currentStatus() throws -> PharosRuntimeStatus {
        let configuration = store.load()
        let endpoint = try effectiveEndpoint(for: configuration)
        return status(configuration: configuration, endpoint: endpoint)
    }

    @discardableResult
    public func activateSavedRoute() throws -> String {
        let configuration = store.load()
        let endpoint = try effectiveEndpoint(for: configuration)
        if configuration.role == .node {
            try restoreCredential(for: endpoint, previous: configuration)
        }
        activateRoute(endpoint)
        return endpoint
    }

    public func effectiveEndpoint(for configuration: PharosRuntimeConfiguration) throws -> String {
        switch configuration.role {
        case .node:
            return try configuration.validated().validRemoteBrokerEndpoint!
        case .broker:
            return try localBrokerEndpoint()
        }
    }

    private func status(configuration: PharosRuntimeConfiguration,
                        endpoint: String) -> PharosRuntimeStatus {
        PharosRuntimeStatus(
            configuration: configuration,
            effectiveBrokerEndpoint: endpoint,
            nodeRunning: serviceIsLoaded(Self.nodeLabel),
            brokerRunning: configuration.role == .broker && serviceIsLoaded(Self.brokerLabel)
        )
    }

    private func activateRoute(_ endpoint: String) {
        MeshClient.hostTCPEndpoint = nil
        MeshClient.remoteEndpoint = endpoint
        MeshPaths.setDialEndpointFile(endpoint)
    }

    private func requireBroker(at endpoint: String, attempts: Int = 1) throws {
        var lastError = "Broker did not complete the Mesh handshake at \(endpoint)."
        for attempt in 0..<attempts {
            let response = MeshClient.send(MeshRequest(cmd: "capabilities"), to: endpoint, timeoutSec: 2)
            if response.ok { return }
            lastError = response.error ?? lastError
            if attempt + 1 < attempts { Thread.sleep(forTimeInterval: 0.25) }
        }
        throw PharosRuntimeError.brokerUnavailable(lastError)
    }

    private func ensureNode(helper: String, endpoint: String) throws {
        let expected = [helper, "node", "run", "--endpoint", endpoint,
                        "--build-id", buildIdentifier]
        let plist = launchAgentsDirectory.appendingPathComponent("\(Self.nodeLabel).plist")
        let installed = (NSDictionary(contentsOf: plist)?["ProgramArguments"] as? [String]) ?? []
        if installed == expected, serviceIsLoaded(Self.nodeLabel) { return }
        try run(helper, ["node", "install", "--endpoint", endpoint,
                         "--build-id", buildIdentifier])
        guard serviceIsLoaded(Self.nodeLabel) else {
            throw PharosRuntimeError.commandFailed("The Host node LaunchAgent did not start.")
        }
    }

    private func installBroker(helper: String, endpoint: String) throws {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Pharos", isDirectory: true)
        let plist = launchAgentsDirectory.appendingPathComponent("\(Self.brokerLabel).plist")
        let expected = [helper, "serve", "--bind", endpoint, "--data-dir",
                        MeshPaths.dataDirectory.path, "--build-id", buildIdentifier]
        let installed = (NSDictionary(contentsOf: plist)?["ProgramArguments"] as? [String]) ?? []
        if installed == expected, serviceIsLoaded(Self.brokerLabel) { return }
        try FileManager.default.createDirectory(at: launchAgentsDirectory,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let value: [String: Any] = [
            "Label": Self.brokerLabel,
            "ProgramArguments": expected,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 5,
            "ExitTimeOut": 10,
            "ProcessType": "Background",
            "StandardOutPath": logs.appendingPathComponent("mesh-broker.log").path,
            "StandardErrorPath": logs.appendingPathComponent("mesh-broker.log").path,
        ]
        guard (value as NSDictionary).write(to: plist, atomically: true) else {
            throw PharosRuntimeError.commandFailed("Could not write the Broker LaunchAgent.")
        }
        if serviceIsLoaded(Self.brokerLabel) {
            try run("/bin/launchctl", ["bootout", "gui/\(getuid())", plist.path])
        }
        try run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist.path])
    }

    private func uninstallBroker() throws {
        let plist = launchAgentsDirectory.appendingPathComponent("\(Self.brokerLabel).plist")
        if FileManager.default.fileExists(atPath: plist.path) {
            if serviceIsLoaded(Self.brokerLabel) {
                try run("/bin/launchctl", ["bootout", "gui/\(getuid())", plist.path])
            }
            try FileManager.default.removeItem(at: plist)
        }
    }

    private func preserveCurrentCredential(for configuration: PharosRuntimeConfiguration) {
        guard configuration.role == .node,
              let endpoint = configuration.validRemoteBrokerEndpoint else { return }
        preserveCurrentCredential(for: endpoint)
    }

    private func preserveCurrentCredential(for endpoint: String) {
        guard let token = MeshPaths.controlToken else { return }
        var credentials = loadCredentials()
        credentials[endpoint] = token
        saveCredentials(credentials)
    }

    private func restoreCredential(for endpoint: String,
                                   previous: PharosRuntimeConfiguration) throws {
        if let token = loadCredentials()[endpoint] {
            MeshPaths.setControlTokenFile(token)
            return
        }
        // First run after upgrade: the single legacy token belongs to the
        // currently configured remote endpoint, so index it before switching.
        if previous.role == .node,
           previous.validRemoteBrokerEndpoint == endpoint,
           let token = MeshPaths.controlToken {
            var credentials = loadCredentials()
            credentials[endpoint] = token
            saveCredentials(credentials)
            return
        }
        // `pharos-mesh pair redeem` writes both files before the runtime role is
        // changed, which proves the current token belongs to this endpoint.
        if MeshPaths.dialEndpoint == endpoint, let token = MeshPaths.controlToken {
            var credentials = loadCredentials()
            credentials[endpoint] = token
            saveCredentials(credentials)
            return
        }
        throw PharosRuntimeError.missingBrokerCredential(endpoint)
    }

    private func loadCredentials() -> [String: String] {
        guard let data = try? Data(contentsOf: credentialFile),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return values
    }

    private func saveCredentials(_ credentials: [String: String]) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        try? FileManager.default.createDirectory(at: MeshPaths.supportDir,
                                                 withIntermediateDirectories: true)
        try? data.write(to: credentialFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: credentialFile.path)
    }

    private var credentialFile: URL {
        MeshPaths.supportDir.appendingPathComponent("runtime-broker-credentials.json")
    }

    private func helperPath() throws -> String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL.resolvingSymlinksInPath()
        let executableDirectory = executable.deletingLastPathComponent()
        let appContents = executableDirectory.deletingLastPathComponent()
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pharos-mesh"),
            appContents.appendingPathComponent("Helpers/pharos-mesh"),
            executableDirectory.appendingPathComponent("pharos-mesh"),
        ]
        guard let helper = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else { throw PharosRuntimeError.helperUnavailable }
        return helper.path
    }

    private func localBrokerEndpoint() throws -> String {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                          "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        guard let binary = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw PharosRuntimeError.tailscaleUnavailable
        }
        let result = try run(binary, ["ip", "-4"], captureOutput: true)
        guard let ip = result.split(separator: "\n").first.map(String.init), isIPv4(ip) else {
            throw PharosRuntimeError.tailscaleUnavailable
        }
        return "\(ip):47800"
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String],
                     captureOutput: Bool = false) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = captureOutput ? output : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw PharosRuntimeError.commandFailed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            throw PharosRuntimeError.commandFailed(
                "\(URL(fileURLWithPath: executable).lastPathComponent) exited with status \(process.terminationStatus)."
            )
        }
        return captureOutput ? String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) : ""
    }

    private func serviceIsLoaded(_ label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return false }
    }

    private var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var buildIdentifier: String {
        let commit = Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String ?? "development"
        let timestamp = Bundle.main.object(forInfoDictionaryKey: "BuildTimestamp") as? String ?? "unknown-time"
        return "\(commit)@\(timestamp)"
    }

    private func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
