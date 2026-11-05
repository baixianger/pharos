import Foundation
import PharosMeshCore
@_exported import PharosAgentCore

public enum AgentRuntimePaths {
    public static var directory: URL {
        MeshPaths.supportDir.appendingPathComponent("Runtime", isDirectory: true)
    }

    public static var socket: URL {
        if let override = ProcessInfo.processInfo.environment["PHAROS_AGENT_RUNTIME_SOCKET"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return directory.appendingPathComponent("agent-runtime.sock")
    }

    public static var registry: URL {
        directory.appendingPathComponent("agent-runtime-registry.json")
    }
}
