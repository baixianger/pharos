import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum MeshFileIdentityStorageError: Error, Equatable, Sendable {
    case unsupportedPlatform
    case insecureDirectoryPermissions(UInt16)
    case insecureFilePermissions(UInt16)
    case notDirectory
    case notRegularFile
    case oversizedFile
    case io(operation: String, code: Int32)
}

/// Headless identity storage. Callers choose the service-owned path; the parent
/// directory must be private and the identity file is atomically linked into
/// place with mode 0600. Existing symlinks and permissive files are rejected.
public struct MeshFileIdentityStorage: MeshIdentityStorage, Sendable {
    private static let maximumBytes = 4 * 1024
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> Data? {
#if canImport(Darwin) || canImport(Glibc)
        guard try validatePrivateDirectory(
            fileURL.deletingLastPathComponent(), allowMissing: true
        ) else { return nil }
        let fd = fileURL.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        if fd < 0 {
            let code = errno
            if code == ENOENT { return nil }
            if code == ELOOP { throw MeshFileIdentityStorageError.notRegularFile }
            throw MeshFileIdentityStorageError.io(operation: "open", code: code)
        }
        defer { _ = close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw MeshFileIdentityStorageError.io(operation: "fstat", code: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw MeshFileIdentityStorageError.notRegularFile
        }
        let permissions = UInt16(info.st_mode & 0o777)
        guard permissions & 0o077 == 0 else {
            throw MeshFileIdentityStorageError.insecureFilePermissions(permissions)
        }
        guard info.st_size >= 0, info.st_size <= Self.maximumBytes else {
            throw MeshFileIdentityStorageError.oversizedFile
        }

        let totalBytes = Int(info.st_size)
        var data = Data(count: totalBytes)
        var offset = 0
        while offset < totalBytes {
            let count = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return read(fd, base.advanced(by: offset), totalBytes - offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw MeshFileIdentityStorageError.io(operation: "read", code: errno)
            }
            guard count > 0 else {
                throw MeshFileIdentityStorageError.io(operation: "short-read", code: 0)
            }
            offset += count
        }
        return data
#else
        throw MeshFileIdentityStorageError.unsupportedPlatform
#endif
    }

    public func insertIfAbsent(_ data: Data) throws -> Bool {
#if canImport(Darwin) || canImport(Glibc)
        guard data.count <= Self.maximumBytes else {
            throw MeshFileIdentityStorageError.oversizedFile
        }
        let directory = fileURL.deletingLastPathComponent()
        try ensurePrivateDirectory(directory)

        let temporary = directory.appendingPathComponent(".identity-\(UUID().uuidString).tmp")
        let fd = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else {
            throw MeshFileIdentityStorageError.io(operation: "create", code: errno)
        }
        var shouldRemoveTemporary = true
        defer {
            _ = close(fd)
            if shouldRemoveTemporary { temporary.path.withCString { _ = unlink($0) } }
        }

        let totalBytes = data.count
        var offset = 0
        while offset < totalBytes {
            let count = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return write(fd, base.advanced(by: offset), totalBytes - offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw MeshFileIdentityStorageError.io(operation: "write", code: errno)
            }
            guard count > 0 else {
                throw MeshFileIdentityStorageError.io(operation: "short-write", code: 0)
            }
            offset += count
        }
        guard fsync(fd) == 0 else {
            throw MeshFileIdentityStorageError.io(operation: "fsync", code: errno)
        }

        let linkResult = temporary.path.withCString { source in
            fileURL.path.withCString { destination in link(source, destination) }
        }
        if linkResult != 0 {
            let code = errno
            if code == EEXIST { return false }
            throw MeshFileIdentityStorageError.io(operation: "link", code: code)
        }
        temporary.path.withCString { _ = unlink($0) }
        shouldRemoveTemporary = false
        try syncDirectory(directory)
        return true
#else
        throw MeshFileIdentityStorageError.unsupportedPlatform
#endif
    }

    /// Atomically replaces an existing protected value. This is intentionally
    /// separate from `MeshIdentityStorage`: device identities stay
    /// insert-only, while small user-selected profiles may opt into explicit
    /// replacement.
    public func replace(_ data: Data) throws {
#if canImport(Darwin) || canImport(Glibc)
        guard data.count <= Self.maximumBytes else {
            throw MeshFileIdentityStorageError.oversizedFile
        }
        let directory = fileURL.deletingLastPathComponent()
        try ensurePrivateDirectory(directory)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try load()
        }

        let temporary = directory.appendingPathComponent(".identity-\(UUID().uuidString).tmp")
        let fd = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else {
            throw MeshFileIdentityStorageError.io(operation: "create", code: errno)
        }
        var shouldRemoveTemporary = true
        defer {
            _ = close(fd)
            if shouldRemoveTemporary { temporary.path.withCString { _ = unlink($0) } }
        }

        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return write(fd, base.advanced(by: offset), data.count - offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw MeshFileIdentityStorageError.io(operation: "write", code: errno)
            }
            guard count > 0 else {
                throw MeshFileIdentityStorageError.io(operation: "short-write", code: 0)
            }
            offset += count
        }
        guard fsync(fd) == 0 else {
            throw MeshFileIdentityStorageError.io(operation: "fsync", code: errno)
        }
        guard temporary.path.withCString({ source in
            fileURL.path.withCString { destination in rename(source, destination) }
        }) == 0 else {
            throw MeshFileIdentityStorageError.io(operation: "rename", code: errno)
        }
        shouldRemoveTemporary = false
        try syncDirectory(directory)
#else
        throw MeshFileIdentityStorageError.unsupportedPlatform
#endif
    }

#if canImport(Darwin) || canImport(Glibc)
    private func ensurePrivateDirectory(_ directory: URL) throws {
        if try validatePrivateDirectory(directory, allowMissing: true) { return }
        let result = directory.path.withCString { mkdir($0, 0o700) }
        if result != 0, errno != EEXIST {
            throw MeshFileIdentityStorageError.io(operation: "create-directory", code: errno)
        }
        _ = try validatePrivateDirectory(directory, allowMissing: false)
    }

    private func validatePrivateDirectory(_ directory: URL,
                                          allowMissing: Bool) throws -> Bool {
        var info = stat()
        guard directory.path.withCString({ lstat($0, &info) }) == 0 else {
            let code = errno
            if allowMissing, code == ENOENT { return false }
            throw MeshFileIdentityStorageError.io(operation: "lstat-directory", code: code)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw MeshFileIdentityStorageError.notDirectory
        }
        let permissions = UInt16(info.st_mode & 0o777)
        guard permissions & 0o077 == 0 else {
            throw MeshFileIdentityStorageError.insecureDirectoryPermissions(permissions)
        }
        return true
    }

    private func syncDirectory(_ directory: URL) throws {
        let fd = directory.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
        guard fd >= 0 else {
            throw MeshFileIdentityStorageError.io(operation: "open-directory", code: errno)
        }
        defer { _ = close(fd) }
        guard fsync(fd) == 0 else {
            throw MeshFileIdentityStorageError.io(operation: "fsync-directory", code: errno)
        }
    }
#endif
}
