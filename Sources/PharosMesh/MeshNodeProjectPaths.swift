import Foundation

/// Host-owned project UUID to checkout path mapping. Broker data never carries
/// filesystem paths; each Node resolves only identifiers registered locally.
enum MeshNodeProjectPaths {
    private static let defaultsKey = "pharos.localProjectPaths.v1"

    static func path(for projectID: String) -> String? {
        guard validProjectID(projectID), let raw = load()[projectID], isDirectory(raw) else { return nil }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }

    static func set(projectID: String, path: String) throws {
        guard validProjectID(projectID) else { throw PathError.invalidProjectID }
        let value = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        guard isDirectory(value) else { throw PathError.directoryMissing }
        var paths = load(); paths[projectID] = value
        try save(paths)
    }

    static func clear(projectID: String) throws {
        guard validProjectID(projectID) else { throw PathError.invalidProjectID }
        var paths = load(); paths.removeValue(forKey: projectID)
        try save(paths)
    }

    static func all() -> [String: String] { load() }

    private static func validProjectID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    private static func load() -> [String: String] {
        #if os(macOS)
        guard let data = UserDefaults(suiteName: "me.pai.pharos")?.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return value
        #else
        guard let data = try? Data(contentsOf: linuxFile),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return value
        #endif
    }

    private static func save(_ paths: [String: String]) throws {
        let data = try JSONEncoder().encode(paths)
        #if os(macOS)
        UserDefaults(suiteName: "me.pai.pharos")?.set(data, forKey: defaultsKey)
        #else
        try FileManager.default.createDirectory(at: linuxFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: linuxFile, options: .atomic)
        #endif
    }

    #if !os(macOS)
    private static var linuxFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pharos/host-project-paths.json")
    }
    #endif

    enum PathError: LocalizedError {
        case invalidProjectID, directoryMissing
        var errorDescription: String? {
            switch self {
            case .invalidProjectID: "Project id must be a UUID."
            case .directoryMissing: "Project path is not an existing directory."
            }
        }
    }
}
