import Foundation
import PharosMeshProtocol
#if canImport(Darwin)
import Darwin
#endif

public struct DistributedMeshLaunchAgentStatus:
    Codable, Equatable, Sendable
{
    public var installed: Bool
    public var loaded: Bool
    public var restartCount: Int?
    public var lockOwner: DistributedMeshRuntimeLock.Metadata?
    public var runtime: DistributedMeshLocalServiceStatus?
    public var diagnostic: String?

    public init(
        installed: Bool, loaded: Bool,
        restartCount: Int? = nil,
        lockOwner: DistributedMeshRuntimeLock.Metadata? = nil,
        runtime: DistributedMeshLocalServiceStatus? = nil,
        diagnostic: String? = nil
    ) {
        self.installed = installed
        self.loaded = loaded
        self.restartCount = restartCount
        self.lockOwner = lockOwner
        self.runtime = runtime
        self.diagnostic = diagnostic
    }
}

public struct DistributedMeshServiceIdentity:
    Codable, Equatable, Sendable
{
    public let deviceID: MeshDeviceID
    public let endpointID: MeshEndpointID
    public let trustGroupID: MeshTrustGroupID
    public let membershipEpoch: UInt64

    public init(
        deviceID: MeshDeviceID, endpointID: MeshEndpointID,
        trustGroupID: MeshTrustGroupID, membershipEpoch: UInt64
    ) {
        self.deviceID = deviceID
        self.endpointID = endpointID
        self.trustGroupID = trustGroupID
        self.membershipEpoch = membershipEpoch
    }

    public init(status: DistributedMeshLocalServiceStatus) {
        self.init(
            deviceID: status.deviceID,
            endpointID: status.endpointID,
            trustGroupID: status.trustGroupID,
            membershipEpoch: status.membershipEpoch
        )
    }
}

public enum DistributedMeshLaunchAgentError:
    LocalizedError, Equatable, Sendable
{
    case unsupportedPlatform
    case helperNotFound
    case helperNotExecutable
    case invalidHelperPath
    case copyFailed(String)
    case plistFailed(String)
    case launchctlFailed(String)
    case replacementIdentityChanged
    case replacementDidNotBecomeHealthy

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "The Pharos Mesh LaunchAgent is available only on macOS."
        case .helperNotFound:
            "Could not find the packaged pharos-mesh helper."
        case .helperNotExecutable:
            "The packaged pharos-mesh helper is not executable."
        case .invalidHelperPath:
            "The pharos-mesh helper path must be an absolute local file path."
        case .copyFailed(let value):
            "Could not install the Pharos Mesh helper: \(value)"
        case .plistFailed(let value):
            "Could not install the Pharos Mesh LaunchAgent: \(value)"
        case .launchctlFailed(let value):
            "launchctl could not activate the Pharos Mesh service: \(value)"
        case .replacementIdentityChanged:
            "The replacement Mesh service opened a different device, " +
                "Endpoint, trust group, or membership epoch."
        case .replacementDidNotBecomeHealthy:
            "The replacement Mesh service did not become healthy before " +
                "the upgrade deadline."
        }
    }
}

public struct DistributedMeshLaunchAgentPlan: Sendable {
    public static let label = "me.pai.pharos.mesh-service"

    public let homeDirectory: URL
    public let dataDirectory: URL
    public let sourceHelper: URL
    public let buildID: String?

    public init(
        homeDirectory: URL, dataDirectory: URL, sourceHelper: URL,
        buildID: String? = nil
    ) throws {
        guard homeDirectory.isFileURL, homeDirectory.path.hasPrefix("/"),
              dataDirectory.isFileURL, dataDirectory.path.hasPrefix("/"),
              sourceHelper.isFileURL, sourceHelper.path.hasPrefix("/")
        else {
            throw DistributedMeshLaunchAgentError.invalidHelperPath
        }
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.dataDirectory = dataDirectory.standardizedFileURL
        self.sourceHelper = sourceHelper.standardizedFileURL
        self.buildID = buildID
    }

    public var runtimeDirectory: URL {
        dataDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Runtime", isDirectory: true)
    }

    public var installedHelper: URL {
        runtimeDirectory.appendingPathComponent("pharos-mesh")
    }

    public var previousHelper: URL {
        runtimeDirectory.appendingPathComponent("pharos-mesh.previous")
    }

    public var plistURL: URL {
        homeDirectory.appendingPathComponent(
            "Library/LaunchAgents/\(Self.label).plist"
        )
    }

    public var logURL: URL {
        homeDirectory.appendingPathComponent(
            "Library/Logs/Pharos/mesh-service.log"
        )
    }

    public var launchArguments: [String] {
        var values = [
            installedHelper.path,
            "distributed", "sync-serve", "--host",
            "--relay", "production", "--service-mode",
        ]
        if let buildID, !buildID.isEmpty {
            values += ["--build-id", buildID]
        }
        return values
    }

    public func plistData() throws -> Data {
        let value: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": launchArguments,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 2,
            "ProcessType": "Background",
            "WorkingDirectory": dataDirectory.path,
            "Umask": 0o077,
            "EnvironmentVariables": [
                "PATH": [
                    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                    "/bin", "/usr/sbin", "/sbin",
                ].joined(separator: ":"),
            ],
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: value, format: .xml, options: 0
        )
    }
}

public enum DistributedMeshLaunchAgent {
    public static func validateReplacementIdentity(
        expected: DistributedMeshServiceIdentity,
        status: DistributedMeshLocalServiceStatus
    ) throws {
        guard DistributedMeshServiceIdentity(status: status) == expected else {
            throw DistributedMeshLaunchAgentError.replacementIdentityChanged
        }
    }

    public static func defaultSourceHelper() -> URL? {
        let fileManager = FileManager.default
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        if executable.lastPathComponent == "pharos-mesh",
           fileManager.isExecutableFile(atPath: executable.path) {
            return executable
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/pharos-mesh")
        if fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let sibling = executable.deletingLastPathComponent()
            .appendingPathComponent("pharos-mesh")
        if fileManager.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        return nil
    }

    public static func install(_ plan: DistributedMeshLaunchAgentPlan) throws {
#if os(macOS)
        do {
            try DistributedMeshHelperDeployment.deploy(plan)
        } catch {
            if let known = error as? DistributedMeshLaunchAgentError {
                throw known
            }
            throw DistributedMeshLaunchAgentError.copyFailed(
                error.localizedDescription
            )
        }
        do {
            try DistributedMeshHelperDeployment.writePlist(plan)
        } catch {
            _ = try? DistributedMeshHelperDeployment.restorePrevious(plan)
            throw DistributedMeshLaunchAgentError.plistFailed(
                error.localizedDescription
            )
        }
        _ = launchctl(["bootout", domain, plan.plistURL.path])
        let result = launchctl(["bootstrap", domain, plan.plistURL.path])
        guard result.status == 0 else {
            if (try? DistributedMeshHelperDeployment.restorePrevious(plan))
                == true {
                _ = launchctl(["bootstrap", domain, plan.plistURL.path])
            }
            throw DistributedMeshLaunchAgentError.launchctlFailed(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
#else
        throw DistributedMeshLaunchAgentError.unsupportedPlatform
#endif
    }

    public static func restart(_ plan: DistributedMeshLaunchAgentPlan) throws {
#if os(macOS)
        let result = launchctl([
            "kickstart", "-k",
            "\(domain)/\(DistributedMeshLaunchAgentPlan.label)",
        ])
        guard result.status == 0 else {
            throw DistributedMeshLaunchAgentError.launchctlFailed(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
#else
        throw DistributedMeshLaunchAgentError.unsupportedPlatform
#endif
    }

    public static func stop(_ plan: DistributedMeshLaunchAgentPlan) throws {
#if os(macOS)
        let result = launchctl(["bootout", domain, plan.plistURL.path])
        // launchctl returns a non-zero code when the job is already absent.
        // Treat that state as stopped when its service label is not loaded.
        if result.status != 0 {
            let status = launchctl([
                "print",
                "\(domain)/\(DistributedMeshLaunchAgentPlan.label)",
            ])
            guard status.status != 0 else {
                throw DistributedMeshLaunchAgentError.launchctlFailed(
                    result.output.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                )
            }
        }
#else
        throw DistributedMeshLaunchAgentError.unsupportedPlatform
#endif
    }

    public static func start(_ plan: DistributedMeshLaunchAgentPlan) throws {
#if os(macOS)
        let result = launchctl([
            "bootstrap", domain, plan.plistURL.path,
        ])
        if result.status != 0 {
            let status = launchctl([
                "print",
                "\(domain)/\(DistributedMeshLaunchAgentPlan.label)",
            ])
            guard status.status == 0 else {
                throw DistributedMeshLaunchAgentError.launchctlFailed(
                    result.output.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                )
            }
        }
#else
        throw DistributedMeshLaunchAgentError.unsupportedPlatform
#endif
    }

    public static func status(
        _ plan: DistributedMeshLaunchAgentPlan
    ) -> DistributedMeshLaunchAgentStatus {
        let fileManager = FileManager.default
        let installed = fileManager.fileExists(atPath: plan.plistURL.path)
            && fileManager.isExecutableFile(atPath: plan.installedHelper.path)
#if os(macOS)
        let result = launchctl([
            "print", "\(domain)/\(DistributedMeshLaunchAgentPlan.label)",
        ])
        let loaded = result.status == 0
        let restartCount = launchdRestartCount(from: result.output)
#else
        let loaded = false
        let restartCount: Int? = nil
#endif
        let runtime: DistributedMeshLocalServiceStatus?
        do {
            runtime = try DistributedMeshLocalServiceClient(
                dataDirectory: plan.dataDirectory
            ).request(.health).status
        } catch {
            runtime = nil
        }
        return DistributedMeshLaunchAgentStatus(
            installed: installed, loaded: loaded,
            restartCount: restartCount,
            lockOwner: DistributedMeshRuntimeLock.currentMetadata(
                dataDirectory: plan.dataDirectory
            ),
            runtime: runtime,
            diagnostic: {
                if !installed { return "service-not-installed" }
                if !loaded { return "launch-agent-not-loaded" }
                if runtime == nil { return "local-control-unavailable" }
                return nil
            }()
        )
    }

    public static func uninstall(
        _ plan: DistributedMeshLaunchAgentPlan
    ) throws {
#if os(macOS)
        _ = launchctl(["bootout", domain, plan.plistURL.path])
        try DistributedMeshHelperDeployment.removeRuntimeArtifacts(plan)
#else
        throw DistributedMeshLaunchAgentError.unsupportedPlatform
#endif
    }

#if os(macOS)
    private static var domain: String { "gui/\(getuid())" }

    static func launchdRestartCount(from output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let fields = line.split(
                separator: "=", maxSplits: 1
            ).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count == 2, fields[0] == "runs",
                  let runs = Int(fields[1]) else { continue }
            return max(0, runs - 1)
        }
        return nil
    }

    private static func launchctl(
        _ arguments: [String]
    ) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        do { try process.run() }
        catch { return (1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
        )
    }

#endif
}

enum DistributedMeshHelperDeployment {
    static func deploy(_ plan: DistributedMeshLaunchAgentPlan) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: plan.sourceHelper.path) else {
            throw DistributedMeshLaunchAgentError.helperNotFound
        }
        guard fileManager.isExecutableFile(atPath: plan.sourceHelper.path) else {
            throw DistributedMeshLaunchAgentError.helperNotExecutable
        }
        try fileManager.createDirectory(
            at: plan.runtimeDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: plan.plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: plan.logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let staged = plan.runtimeDirectory.appendingPathComponent(
            "pharos-mesh.staged-\(getpid())"
        )
        if fileManager.fileExists(atPath: staged.path) {
            try fileManager.removeItem(at: staged)
        }
        defer {
            if fileManager.fileExists(atPath: staged.path) {
                try? fileManager.removeItem(at: staged)
            }
        }
        try fileManager.copyItem(at: plan.sourceHelper, to: staged)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: staged.path
        )
        if fileManager.fileExists(atPath: plan.previousHelper.path) {
            try fileManager.removeItem(at: plan.previousHelper)
        }
        if fileManager.fileExists(atPath: plan.installedHelper.path) {
            try fileManager.moveItem(
                at: plan.installedHelper, to: plan.previousHelper
            )
        }
        try fileManager.moveItem(at: staged, to: plan.installedHelper)
    }

    @discardableResult
    static func restorePrevious(
        _ plan: DistributedMeshLaunchAgentPlan
    ) throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: plan.previousHelper.path) else {
            return false
        }
        if fileManager.fileExists(atPath: plan.installedHelper.path) {
            try fileManager.removeItem(at: plan.installedHelper)
        }
        try fileManager.moveItem(
            at: plan.previousHelper, to: plan.installedHelper
        )
        return true
    }

    static func writePlist(
        _ plan: DistributedMeshLaunchAgentPlan
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: plan.plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try plan.plistData().write(
            to: plan.plistURL, options: .atomic
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: plan.plistURL.path
        )
    }

    static func removeRuntimeArtifacts(
        _ plan: DistributedMeshLaunchAgentPlan
    ) throws {
        let fileManager = FileManager.default
        for url in [
            plan.plistURL, plan.installedHelper, plan.previousHelper,
        ] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        let socket = try? DistributedMeshLocalServicePaths.socketURL(
            dataDirectory: plan.dataDirectory
        )
        if let socket, fileManager.fileExists(atPath: socket.path) {
            try fileManager.removeItem(at: socket)
        }
    }
}
