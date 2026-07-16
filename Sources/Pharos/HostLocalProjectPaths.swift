import Foundation

/// Checkout paths belong to an execution Host, not to the portable Broker
/// registry. The project UUID is stable across devices; each Host keeps only
/// its own UUID → absolute-path map in local preferences.
enum HostLocalProjectPaths {
    private static let key = "pharos.localProjectPaths.v1"

    static func apply(to store: inout StoreData) {
        var paths = load()
        let original = paths
        apply(to: &store, paths: &paths, host: HostIdentity.current)
        if paths != original { save(paths) }
    }

    static func apply(to store: inout StoreData, paths: inout [String: String], host: String) {
        for index in store.projects.indices {
            let id = store.projects[index].id
            if paths[id.uuidString] == nil,
               let legacy = store.projects[index].resolvedLocalPath(forHost: host),
               !legacy.isEmpty {
                paths[id.uuidString] = legacy
            }
            store.projects[index].localPath = paths[id.uuidString]
            store.projects[index].localPaths = [:]
        }
    }

    /// Persist this Host's currently resolved paths, then remove all paths from
    /// the snapshot that will be sent to the Broker.
    static func captureAndStrip(_ store: inout StoreData) {
        var paths = load()
        captureAndStrip(&store, paths: &paths)
        save(paths)
    }

    static func captureAndStrip(_ store: inout StoreData, paths: inout [String: String]) {
        for index in store.projects.indices {
            let id = store.projects[index].id.uuidString
            if let path = store.projects[index].localPath, !path.isEmpty {
                paths[id] = path
            } else {
                paths.removeValue(forKey: id)
            }
            store.projects[index].localPath = nil
            store.projects[index].localPaths = [:]
        }
    }

    static func path(for projectID: UUID) -> String? { load()[projectID.uuidString] }

    private static func load() -> [String: String] {
        guard let data = PharosPrefs.shared.data(forKey: key),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return value
    }

    private static func save(_ paths: [String: String]) {
        guard let data = try? JSONEncoder().encode(paths) else { return }
        PharosPrefs.shared.set(data, forKey: key)
    }
}
