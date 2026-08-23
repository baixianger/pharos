import PharosAgentCore

final class AgentAdapterRegistry: @unchecked Sendable {
    private let adapters: [String: any AgentAdapter]

    init(adapters: [any AgentAdapter]) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.manifest.id, $0) })
    }

    func manifests() -> [AgentAdapterManifest] {
        adapters.values.map(\.manifest).sorted { $0.id < $1.id }
    }

    func adapter(id: String) throws -> any AgentAdapter {
        guard let adapter = adapters[id] else {
            throw AgentRuntimeRegistry.RegistryError.notFound("Unknown adapter: \(id)")
        }
        return adapter
    }
}
