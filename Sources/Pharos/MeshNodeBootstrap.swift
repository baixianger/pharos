import Foundation

/// Keeps the per-user Host node independent from the GUI lifecycle. Packaged
/// apps embed the portable helper; development SwiftPM binaries simply skip
/// bootstrap because they have no sealed helper beside them.
enum MeshNodeBootstrap {
    private static let label = "me.pai.pharos.mesh-node"

    static func ensureInstalled(endpoint: String?) {
        guard let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/pharos-mesh").path.nilIfEmpty,
              FileManager.default.isExecutableFile(atPath: helper) else { return }
        let expected = [helper, "node", "run"] + (endpoint.map { ["--endpoint", $0] } ?? [])
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let installedArguments = (NSDictionary(contentsOf: plist)?["ProgramArguments"] as? [String]) ?? []
        if installedArguments == expected, serviceIsLoaded() { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["node", "install"] + (endpoint.map { ["--endpoint", $0] } ?? [])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() }
        catch { return }
    }

    private static func serviceIsLoaded() -> Bool {
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
