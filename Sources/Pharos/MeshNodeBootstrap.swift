import Foundation

/// Keeps the per-user Host node independent from the GUI lifecycle. Packaged
/// apps embed the portable helper; development SwiftPM binaries simply skip
/// bootstrap because they have no sealed helper beside them.
enum MeshNodeBootstrap {
    private static let nodeLabel = "me.pai.pharos.mesh-node"
    private static let brokerLabel = "me.pai.pharos.mesh-broker"

    static func reconcile(enabled: Bool, brokerEndpoint: String?, nodeEndpoint: String?) {
        guard let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/pharos-mesh").path.nilIfEmpty,
              FileManager.default.isExecutableFile(atPath: helper) else { return }
        if !enabled {
            run(helper, ["node", "uninstall"])
            uninstallBroker()
            return
        }
        if let brokerEndpoint {
            installBroker(helper: helper, endpoint: brokerEndpoint)
        } else {
            uninstallBroker()
        }
        ensureNode(helper: helper, endpoint: nodeEndpoint)
    }

    private static func ensureNode(helper: String, endpoint: String?) {
        let expected = [helper, "node", "run"] + (endpoint.map { ["--endpoint", $0] } ?? [])
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(nodeLabel).plist")
        let installedArguments = (NSDictionary(contentsOf: plist)?["ProgramArguments"] as? [String]) ?? []
        if installedArguments == expected, serviceIsLoaded(nodeLabel) { return }

        run(helper, ["node", "install"] + (endpoint.map { ["--endpoint", $0] } ?? []))
    }

    private static func installBroker(helper: String, endpoint: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Pharos", isDirectory: true)
        let plist = directory.appendingPathComponent("\(brokerLabel).plist")
        let expected = [helper, "serve", "--bind", endpoint, "--data-dir", MeshPaths.dataDirectory.path]
        let installed = (NSDictionary(contentsOf: plist)?["ProgramArguments"] as? [String]) ?? []
        if installed == expected, serviceIsLoaded(brokerLabel) { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let value: [String: Any] = [
            "Label": brokerLabel,
            "ProgramArguments": expected,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": logs.appendingPathComponent("mesh-broker.log").path,
            "StandardErrorPath": logs.appendingPathComponent("mesh-broker.log").path,
        ]
        guard (value as NSDictionary).write(to: plist, atomically: true) else { return }
        run("/bin/launchctl", ["bootout", "gui/\(getuid())", plist.path])
        run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist.path])
    }

    private static func uninstallBroker() {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(brokerLabel).plist")
        run("/bin/launchctl", ["bootout", "gui/\(getuid())", plist.path])
        try? FileManager.default.removeItem(at: plist)
    }

    private static func run(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() }
        catch { return }
    }

    private static func serviceIsLoaded(_ label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return false }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
