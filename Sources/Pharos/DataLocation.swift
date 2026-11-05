import Foundation
import PharosMeshCore

/// The app's preferences domain (`me.pai.pharos`) no matter which front door
/// the process came through.
///
/// Invoked via a `pharos`/`chat` symlink (or the bare dev binary), Bundle.main
/// does NOT resolve to the .app bundle, so `PharosPrefs.shared` silently
/// reads/writes a per-process "pharos" domain instead of the app's. The CLI
/// then misses `pharos.dataDir` and splits onto its own registry in
/// Application Support while the GUI follows the pref into iCloud — two
/// diverging stores (the actual Pharos#6 root cause; the rename was innocent).
/// EVERY pref access must go through `PharosPrefs.shared`.
enum PharosPrefs {
    static let appDomain = "me.pai.pharos"
    static var shared: UserDefaults {
        if Bundle.main.bundleIdentifier == appDomain { return .standard }
        return UserDefaults(suiteName: appDomain) ?? .standard
    }
}

/// Local cache location for Broker-owned project data. iCloud was the old
/// multi-Mac transport; it is now imported once and retained only as a backup.
enum DataLocation {
    private static let defaultsKey = "pharos.dataDir"
    private static let folderName = "Pharos"

    /// `~/Library/Application Support/Pharos`.
    static var appSupportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Caches and downloaded attachment bytes are always local to this device.
    static var current: URL { appSupportDirectory }

    /// One-time upgrade bridge: seed the local cache from the previously chosen
    /// local/iCloud directory, then stop treating that directory as live state.
    /// The source is deliberately left untouched as an additional rollback copy.
    static func migrateLegacyCacheIfNeeded() {
        let prefs = PharosPrefs.shared
        guard !prefs.bool(forKey: "pharos.brokerCacheMigrated") else { return }
        defer {
            prefs.set(true, forKey: "pharos.brokerCacheMigrated")
            prefs.removeObject(forKey: defaultsKey)
        }
        guard let oldPath = prefs.string(forKey: defaultsKey), !oldPath.isEmpty else { return }
        let source = URL(fileURLWithPath: oldPath, isDirectory: true).standardizedFileURL
        let target = appSupportDirectory.standardizedFileURL
        guard source != target else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        let sourceRegistry = source.appendingPathComponent("projects.json")
        let targetRegistry = target.appendingPathComponent("projects.json")
        if fm.fileExists(atPath: sourceRegistry.path) {
            if fm.fileExists(atPath: targetRegistry.path) {
                let rollback = target.appendingPathComponent("projects.pre-broker-cache.json")
                try? fm.removeItem(at: rollback)
                try? fm.copyItem(at: targetRegistry, to: rollback)
                try? fm.removeItem(at: targetRegistry)
            }
            try? fm.copyItem(at: sourceRegistry, to: targetRegistry)
        }
        mergeMissingFiles(from: source.appendingPathComponent("attachments"),
                          into: target.appendingPathComponent("attachments"), fileManager: fm)
    }

    private static func mergeMissingFiles(from source: URL, into target: URL,
                                          fileManager fm: FileManager) {
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }
        for case let item as URL in enumerator {
            guard item.path.hasPrefix(source.path + "/") else { continue }
            let relative = String(item.path.dropFirst(source.path.count + 1))
            let destination = target.appendingPathComponent(relative)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
            } else if !fm.fileExists(atPath: destination.path) {
                try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: item, to: destination)
            }
        }
    }

}

/// Device cache for issue attachment bytes. Distributed metadata is signed into
/// the replica and content-addressed bytes are fetched from trusted peers.
enum AttachmentStore {
    static var baseDirectory: URL {
        PharosCore.registryURL.deletingLastPathComponent()
            .appendingPathComponent("attachments", isDirectory: true)
    }

    static func directory(forIssue id: UUID) -> URL {
        baseDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func fileURL(_ attachment: IssueAttachment, issueID: UUID) -> URL {
        let url = directory(forIssue: issueID).appendingPathComponent(attachment.storedName)
        if !FileManager.default.fileExists(atPath: url.path),
           !PharosMeshRuntimeMode.usesDistributedMesh,
           ProcessInfo.processInfo.environment["PHAROS_REGISTRY"] == nil {
            _ = try? MeshClient.downloadAttachment(id: attachment.id.uuidString, to: url)
        }
        return url
    }

    private static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp"]

    /// Copy a source file into an issue's attachment directory, returning its
    /// metadata. The stored name is unique (UUID-prefixed) to avoid collisions.
    @discardableResult
    static func add(fileAt source: URL, toIssue id: UUID) throws -> IssueAttachment {
        try add(fileAt: source, toIssue: id, distributedReference: nil)
    }

    /// Copies bytes into the device cache and binds them to distributed blob
    /// metadata without contacting the retired Broker.
    static func add(
        fileAt source: URL, toIssue id: UUID,
        distributedReference: MeshAttachment?
    ) throws -> IssueAttachment {
        let fm = FileManager.default
        let dir = directory(forIssue: id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = source.pathExtension
        let stored = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let dest = dir.appendingPathComponent(stored)
        try fm.copyItem(at: source, to: dest)
        let id = UUID()
        if distributedReference == nil,
           ProcessInfo.processInfo.environment["PHAROS_REGISTRY"] == nil {
            do {
                _ = try MeshClient.uploadAttachment(fileAt: dest, id: id.uuidString,
                                                    name: source.lastPathComponent)
            } catch {
                try? fm.removeItem(at: dest)
                throw error
            }
        }
        let attrs = try? fm.attributesOfItem(atPath: dest.path)
        let size = (attrs?[.size] as? Int) ?? 0
        return IssueAttachment(
            id: id,
            storedName: stored,
            originalName: source.lastPathComponent,
            isImage: imageExtensions.contains(ext.lowercased()),
            byteSize: size,
            meshAttachment: distributedReference
        )
    }

    static func storeDistributedData(
        _ data: Data, for attachment: IssueAttachment, issueID: UUID
    ) throws -> URL {
        let directory = directory(forIssue: issueID)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let destination = directory.appendingPathComponent(attachment.storedName)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Delete every attachment directory whose issue id is not in `keep` — orphan
    /// cleanup for issues that were permanently purged from the Trash.
    static func sweepOrphans(keepingIssueIDs keep: Set<UUID>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
            if !keep.contains(id) { try? fm.removeItem(at: entry) }
        }
    }
}
