import Foundation

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

/// Resolves where Pharos keeps its data (the registry + attachments).
///
/// Default is `~/Library/Application Support/Pharos`. The user can move it into
/// **iCloud Drive** (Settings → Data location) so project data — issues, logs,
/// notes — syncs across their Macs; per-host local checkout paths
/// (`Project.localPaths`) keep each machine's own path intact. This is plain
/// iCloud Drive (a folder under `com~apple~CloudDocs`), so it needs no iCloud
/// entitlement and works with any signing/distribution.
///
/// Both front doors read the same `pharos.dataDir` default, so the GUI and the
/// `pharos` CLI always agree on the location.
enum DataLocation {
    private static let defaultsKey = "pharos.dataDir"
    private static let folderName = "Pharos"

    /// `~/Library/Application Support/Pharos`.
    static var appSupportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/Pharos`, or nil if the
    /// user doesn't have iCloud Drive enabled (the CloudDocs container is absent).
    static var iCloudDirectory: URL? {
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: cloudDocs.path) else { return nil }
        return cloudDocs.appendingPathComponent(folderName, isDirectory: true)
    }

    /// True iff iCloud Drive is available on this Mac.
    static var iCloudAvailable: Bool { iCloudDirectory != nil }

    /// The active data directory: the user's `pharos.dataDir` override, else the
    /// Application Support default.
    static var current: URL {
        if let custom = PharosPrefs.shared.string(forKey: defaultsKey), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return appSupportDirectory
    }

    /// True iff the active directory is the iCloud Drive folder.
    static var usingICloud: Bool {
        guard let custom = PharosPrefs.shared.string(forKey: defaultsKey), !custom.isEmpty,
              let icloud = iCloudDirectory else { return false }
        return URL(fileURLWithPath: custom).standardizedFileURL == icloud.standardizedFileURL
    }

    static func setDirectory(_ url: URL?) {
        if let url {
            PharosPrefs.shared.set(url.path, forKey: defaultsKey)
        } else {
            PharosPrefs.shared.removeObject(forKey: defaultsKey)
        }
    }

}

/// Stores issue attachment bytes on disk under `<registry dir>/attachments/<issueID>/`.
/// The registry holds only metadata (`IssueAttachment`); this is the only place
/// that touches the files. Derived from `PharosCore.registryURL` so it always
/// sits beside the active registry — following `PHAROS_REGISTRY`, the
/// `pharos.dataDir` pref, and iCloud relocation alike.
enum AttachmentStore {
    static var baseDirectory: URL {
        PharosCore.registryURL.deletingLastPathComponent()
            .appendingPathComponent("attachments", isDirectory: true)
    }

    static func directory(forIssue id: UUID) -> URL {
        baseDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func fileURL(_ attachment: IssueAttachment, issueID: UUID) -> URL {
        directory(forIssue: issueID).appendingPathComponent(attachment.storedName)
    }

    private static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp"]

    /// Copy a source file into an issue's attachment directory, returning its
    /// metadata. The stored name is unique (UUID-prefixed) to avoid collisions.
    @discardableResult
    static func add(fileAt source: URL, toIssue id: UUID) throws -> IssueAttachment {
        let fm = FileManager.default
        let dir = directory(forIssue: id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = source.pathExtension
        let stored = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let dest = dir.appendingPathComponent(stored)
        try fm.copyItem(at: source, to: dest)
        let attrs = try? fm.attributesOfItem(atPath: dest.path)
        let size = (attrs?[.size] as? Int) ?? 0
        return IssueAttachment(
            storedName: stored,
            originalName: source.lastPathComponent,
            isImage: imageExtensions.contains(ext.lowercased()),
            byteSize: size
        )
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
