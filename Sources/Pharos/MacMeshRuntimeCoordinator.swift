import AppKit
import Foundation

@MainActor
final class PharosApplicationDelegate: NSObject, NSApplicationDelegate {
    var shutdownDistributedMesh: (() async -> Void)?
    private var isTerminating = false

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !isTerminating, let shutdownDistributedMesh else {
            return .terminateNow
        }
        isTerminating = true
        Task {
            await shutdownDistributedMesh()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

enum MacMeshRuntimeCoordinator {
    private static let bundleIdentifier = "me.pai.pharos"

    static func requiresExclusiveRuntime(meshArguments: [String]) -> Bool {
        guard let command = meshArguments.first else { return false }
        if command == "pair" {
            guard meshArguments.count >= 2 else { return false }
            return ["invite", "create", "accept", "revoke", "remove"]
                .contains(meshArguments[1])
        }
        if command == "presence" {
            return !meshArguments.contains("--local")
        }
        return command == "stop"
    }

    @MainActor
    static func run(
        _ operation: () async -> Int32
    ) async -> Int32 {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: {
                $0.processIdentifier != currentPID && !$0.isTerminated
            })
        else {
            return await operation()
        }

        let bundleURL = application.bundleURL
        guard application.terminate() else {
            FileHandle.standardError.write(Data(
                "error: close Pharos before running this networked Mesh command\n"
                    .utf8
            ))
            return 1
        }

        let deadline = ContinuousClock.now + .seconds(10)
        while !application.isTerminated && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard application.isTerminated else {
            FileHandle.standardError.write(Data(
                "error: Pharos did not release its Mesh runtime in time\n".utf8
            ))
            return 1
        }

        let result = await operation()
        if let bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(
                at: bundleURL, configuration: configuration
            )
        }
        return result
    }
}
