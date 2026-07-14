import Citadel
import Crypto
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOSSH

actor InteractiveSSHSession {
    private let profile: SSHHostProfile
    private let privateKey: Curve25519.Signing.PrivateKey
    private var client: SSHClient?

    init(profile: SSHHostProfile, privateKey: Curve25519.Signing.PrivateKey) {
        self.profile = profile
        self.privateKey = privateKey
    }

    func connect() async throws {
        guard profile.acceptsUnverifiedHostKey else { throw RemoteActionError.unverifiedHostKey }
        client = try await SSHClient.connect(
            host: profile.sshHost, port: Int(profile.port),
            authenticationMethod: .ed25519(username: profile.username, privateKey: privateKey),
            hostKeyValidator: .acceptAnything(), reconnect: .never
        )
    }

    func openShell(cols: Int = 80, rows: Int = 24) async throws -> InteractiveSSHShell {
        guard let client else { throw InteractiveSSHError.notConnected }
        return try await InteractiveSSHShell.start(client: UnsafeTransfer(value: client), cols: cols, rows: rows)
    }

    func close() async {
        if let client { try? await UnsafeTransfer(value: client).value.close() }
        client = nil
    }
}

enum InteractiveSSHError: LocalizedError {
    case notConnected
    case shellStartup(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "SSH session is not connected."
        case .shellStartup(let detail): "Could not start the remote terminal: \(detail)"
        }
    }
}

private struct UnsafeTransfer<Value>: @unchecked Sendable { let value: Value }

final class InteractiveSSHShell: @unchecked Sendable {
    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let bridge: InteractiveShellBridge

    private init(output: AsyncStream<Data>, continuation: AsyncStream<Data>.Continuation,
                 bridge: InteractiveShellBridge) {
        self.output = output
        self.continuation = continuation
        self.bridge = bridge
    }

    fileprivate static func start(client: UnsafeTransfer<SSHClient>, cols: Int, rows: Int) async throws -> InteractiveSSHShell {
        let (output, continuation) = AsyncStream.makeStream(of: Data.self)
        let (setup, setupContinuation) = AsyncStream<UnsafeTransfer<Result<TTYStdinWriter, any Error>>>.makeStream()
        let bridge = InteractiveShellBridge()
        let task = Task<Void, Never> {
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true, term: "xterm-256color", terminalCharacterWidth: cols,
                terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0,
                terminalModes: .init([:])
            )
            do {
                try await client.value.withPTY(request) { inbound, writer in
                    setupContinuation.yield(UnsafeTransfer(value: .success(writer)))
                    setupContinuation.finish()
                    do {
                        for try await item in inbound {
                            switch item {
                            case .stdout(var buffer), .stderr(var buffer):
                                if let data = buffer.readData(length: buffer.readableBytes) { continuation.yield(data) }
                            }
                        }
                    } catch { }
                    continuation.finish()
                }
            } catch {
                setupContinuation.yield(UnsafeTransfer(value: .failure(error)))
                setupContinuation.finish()
                continuation.finish()
            }
        }
        var iterator = setup.makeAsyncIterator()
        guard let result = await iterator.next() else {
            task.cancel()
            throw InteractiveSSHError.shellStartup("PTY ended before setup completed.")
        }
        switch result.value {
        case .success(let writer):
            bridge.assign(writer: writer, task: task)
            return InteractiveSSHShell(output: output, continuation: continuation, bridge: bridge)
        case .failure(let error):
            throw InteractiveSSHError.shellStartup(error.localizedDescription)
        }
    }

    func write(_ data: Data) async throws {
        guard let writer = bridge.writer?.value else { return }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await writer.write(buffer)
    }

    func resize(cols: Int, rows: Int) async {
        guard let writer = bridge.writer?.value else { return }
        try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    func finish() { continuation.finish(); bridge.cancel() }
}

private final class InteractiveShellBridge: @unchecked Sendable {
    private(set) var writer: UnsafeTransfer<TTYStdinWriter>?
    private var task: Task<Void, Never>?

    func assign(writer: TTYStdinWriter, task: Task<Void, Never>) {
        self.writer = UnsafeTransfer(value: writer)
        self.task = task
    }
    func cancel() { task?.cancel(); task = nil }
}
