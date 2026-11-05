import Foundation

/// Stable identity shared by the Host Node and every local agent registration.
/// The value survives app upgrades and computer-name/IP changes; existing
/// installations retain the identifier already stored on disk.
public enum MeshNodeIdentity {
    public static let current: String = {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pharos", isDirectory: true)
        let file = directory.appendingPathComponent("mesh-node-id")
        if let value = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        let value = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? value.write(to: file, atomically: true, encoding: .utf8)
        return value
    }()
}
