import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum DistributedMeshRuntimeLockError: LocalizedError, Equatable {
    case invalidDataDirectory
    case openFailed(Int32)
    case alreadyOwned(String?)
    case metadataWriteFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidDataDirectory:
            "The distributed Mesh data directory must be an absolute file URL."
        case .openFailed(let code):
            "Could not open the distributed Mesh runtime lock (errno \(code))."
        case .alreadyOwned(let owner):
            if let owner, !owner.isEmpty {
                "The distributed Mesh endpoint is already owned by \(owner)."
            } else {
                "The distributed Mesh endpoint is already owned by another process."
            }
        case .metadataWriteFailed(let code):
            "Could not record distributed Mesh runtime ownership (errno \(code))."
        }
    }
}

/// Excludes a second local process before it binds the device's stable Iroh
/// Endpoint ID. The lock file is intentionally retained after release: removing
/// it would let a racing opener lock an old inode while another process locks a
/// newly-created path.
public final class DistributedMeshRuntimeLock {
    public struct Metadata: Codable, Equatable, Sendable {
        public let owner: String
        public let processID: Int32
        public let startedAtMilliseconds: Int64
        public let buildID: String?

        public init(
            owner: String, processID: Int32 = getpid(),
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

    public static let fileName = "runtime.lock"

    public let fileURL: URL
    public let metadata: Metadata
    private var descriptor: Int32?

    private init(fileURL: URL, metadata: Metadata, descriptor: Int32) {
        self.fileURL = fileURL
        self.metadata = metadata
        self.descriptor = descriptor
    }

    public static func acquire(
        dataDirectory: URL, owner: String, buildID: String? = nil
    ) throws -> DistributedMeshRuntimeLock {
        let directory = dataDirectory.standardizedFileURL
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw DistributedMeshRuntimeLockError.invalidDataDirectory
        }
        let fileURL = directory.appendingPathComponent(fileName)
        let flags = O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW
        let descriptor = open(fileURL.path, flags, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw DistributedMeshRuntimeLockError.openFailed(errno)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            let owner = readMetadata(from: descriptor)?.displayDescription
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw DistributedMeshRuntimeLockError.alreadyOwned(owner)
            }
            throw DistributedMeshRuntimeLockError.openFailed(code)
        }

        let metadata = Metadata(owner: owner, buildID: buildID)
        do {
            try writeMetadata(metadata, to: descriptor)
        } catch {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            throw error
        }
        return DistributedMeshRuntimeLock(
            fileURL: fileURL, metadata: metadata, descriptor: descriptor
        )
    }

    public static func currentMetadata(
        dataDirectory: URL
    ) -> Metadata? {
        let fileURL = dataDirectory.standardizedFileURL
            .appendingPathComponent(fileName)
        let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        // The JSON remains after a clean stop for diagnostics, but it is not
        // a live owner unless another descriptor still holds the flock.
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return nil
        }
        guard errno == EWOULDBLOCK || errno == EAGAIN else {
            return nil
        }
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

    private static func writeMetadata(
        _ metadata: Metadata, to descriptor: Int32
    ) throws {
        var data = try JSONEncoder().encode(metadata)
        data.append(0x0A)
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
              ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) == 0
        else {
            throw DistributedMeshRuntimeLockError.metadataWriteFailed(errno)
        }
        try data.withUnsafeBytes { rawBuffer in
            guard var base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = write(descriptor, base, remaining)
                guard count > 0 else {
                    throw DistributedMeshRuntimeLockError.metadataWriteFailed(errno)
                }
                remaining -= count
                base = base.advanced(by: count)
            }
        }
        guard fsync(descriptor) == 0 else {
            throw DistributedMeshRuntimeLockError.metadataWriteFailed(errno)
        }
    }

    private static func readMetadata(from descriptor: Int32) -> Metadata? {
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = pread(descriptor, &bytes, bytes.count, 0)
        guard count > 0 else { return nil }
        return try? JSONDecoder().decode(
            Metadata.self, from: Data(bytes.prefix(Int(count)))
        )
    }
}
