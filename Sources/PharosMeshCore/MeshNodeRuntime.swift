import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum MeshNodeRuntimeLockError: LocalizedError, Equatable {
    case invalidDirectory
    case openFailed(Int32)
    case alreadyOwned(String?)
    case metadataWriteFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory:
            "The Mesh Node runtime directory must be an absolute file URL."
        case .openFailed(let code):
            "Could not open the Mesh Node runtime lock (errno \(code))."
        case .alreadyOwned(let owner):
            if let owner, !owner.isEmpty {
                "The Mesh Node runtime is already owned by \(owner)."
            } else {
                "The Mesh Node runtime is already owned by another process."
            }
        case .metadataWriteFailed(let code):
            "Could not record Mesh Node runtime ownership (errno \(code))."
        }
    }
}

/// Holds an advisory lock for the lifetime of one local Mesh Node process.
/// The file remains after release so racing processes always lock one inode.
public final class MeshNodeRuntimeLock {
    public struct Metadata: Codable, Equatable, Sendable {
        public let owner: String
        public let processID: Int32
        public let startedAtMilliseconds: Int64
        public let buildID: String?

        public init(
            owner: String,
            processID: Int32 = getpid(),
            startedAtMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
            buildID: String? = nil
        ) {
            self.owner = owner
            self.processID = processID
            self.startedAtMilliseconds = startedAtMilliseconds
            self.buildID = buildID
        }

        fileprivate var displayDescription: String {
            var value = "\(owner) (pid \(processID))"
            if let buildID, !buildID.isEmpty { value += ", build \(buildID)" }
            return value
        }
    }

    public static let fileName = "mesh-node.lock"

    public let fileURL: URL
    public let metadata: Metadata
    private var descriptor: Int32?

    private init(fileURL: URL, metadata: Metadata, descriptor: Int32) {
        self.fileURL = fileURL
        self.metadata = metadata
        self.descriptor = descriptor
    }

    public static func acquire(
        runtimeDirectory: URL,
        owner: String,
        buildID: String? = nil
    ) throws -> MeshNodeRuntimeLock {
        let directory = runtimeDirectory.standardizedFileURL
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw MeshNodeRuntimeLockError.invalidDirectory
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )

        let fileURL = directory.appendingPathComponent(fileName)
        let flags = O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW
        let descriptor = open(fileURL.path, flags, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw MeshNodeRuntimeLockError.openFailed(errno)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            let owner = readMetadata(from: descriptor)?.displayDescription
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw MeshNodeRuntimeLockError.alreadyOwned(owner)
            }
            throw MeshNodeRuntimeLockError.openFailed(code)
        }

        let metadata = Metadata(owner: owner, buildID: buildID)
        do {
            try writeMetadata(metadata, to: descriptor)
        } catch {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            throw error
        }
        return MeshNodeRuntimeLock(
            fileURL: fileURL,
            metadata: metadata,
            descriptor: descriptor
        )
    }

    public static func currentMetadata(runtimeDirectory: URL) -> Metadata? {
        let fileURL = runtimeDirectory.standardizedFileURL
            .appendingPathComponent(fileName)
        let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return nil
        }
        guard errno == EWOULDBLOCK || errno == EAGAIN else { return nil }
        return readMetadata(from: descriptor)
    }

    public func release() {
        guard let descriptor else { return }
        self.descriptor = nil
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit {
        release()
    }

    private static func writeMetadata(_ metadata: Metadata, to descriptor: Int32) throws {
        var data = try JSONEncoder().encode(metadata)
        data.append(0x0A)
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
              ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) == 0
        else {
            throw MeshNodeRuntimeLockError.metadataWriteFailed(errno)
        }
        try data.withUnsafeBytes { rawBuffer in
            guard var base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = write(descriptor, base, remaining)
                guard count > 0 else {
                    throw MeshNodeRuntimeLockError.metadataWriteFailed(errno)
                }
                remaining -= count
                base = base.advanced(by: count)
            }
        }
        guard fsync(descriptor) == 0 else {
            throw MeshNodeRuntimeLockError.metadataWriteFailed(errno)
        }
    }

    private static func readMetadata(from descriptor: Int32) -> Metadata? {
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = pread(descriptor, &bytes, bytes.count, 0)
        guard count > 0 else { return nil }
        return try? JSONDecoder().decode(
            Metadata.self,
            from: Data(bytes.prefix(Int(count)))
        )
    }
}

/// Signal handlers and the Node loop share only this process-local state.
public final class MeshNodeShutdownLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    public init() {}

    public func request() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    public func isRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }
}
