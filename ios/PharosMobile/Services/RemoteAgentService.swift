import Citadel
import Crypto
import Foundation

enum RemoteActionError: LocalizedError {
    case unsafeValue(String)
    case unverifiedHostKey
    case missingIdentity
    case spawnNotConfirmed(String)

    var errorDescription: String? {
        switch self {
        case .unsafeValue(let value): "Unsafe remote value: \(value)"
        case .unverifiedHostKey: "Confirm the SSH host-key risk in Settings first."
        case .missingIdentity: "Choose a device-local SSH identity for this host."
        case .spawnNotConfirmed(let output): "The remote spawn did not confirm that it joined. \(output)"
        }
    }
}

enum MobileAgentKind: String, CaseIterable, Identifiable, Sendable {
    case claude, codex
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum RemoteCommandBuilder {
    static let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    static func spawn(room: String, nick: String, kind: MobileAgentKind) throws -> String {
        guard safe(room) else { throw RemoteActionError.unsafeValue(room) }
        guard safe(nick) else { throw RemoteActionError.unsafeValue(nick) }
        return "export PATH=\(path):$PATH; pharos mesh spawn \(room) \(nick) \(kind.rawValue)"
    }

    static func attach(pane: String) throws -> String {
        let digits = pane.first == "%" ? pane.dropFirst() : Substring(pane)
        guard pane.first == "%", !digits.isEmpty, digits.allSatisfy(\.isNumber) else {
            throw RemoteActionError.unsafeValue(pane)
        }
        return "export PATH=\(path):$PATH; s=$(tmux display-message -p -t '\(pane)' '#{session_name}') || exit 31; exec tmux attach-session -t \"=$s\""
    }

    private static func safe(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }
}

actor RemoteAgentService {
    func spawn(room: String, nick: String, kind: MobileAgentKind, profile: SSHHostProfile,
               privateKey: Curve25519.Signing.PrivateKey) async throws -> String {
        guard profile.acceptsUnverifiedHostKey else { throw RemoteActionError.unverifiedHostKey }
        let command = try RemoteCommandBuilder.spawn(room: room, nick: nick, kind: kind)
        let client = try await SSHClient.connect(
            host: profile.sshHost, port: Int(profile.port),
            authenticationMethod: .ed25519(username: profile.username, privateKey: privateKey),
            hostKeyValidator: .acceptAnything(), reconnect: .never
        )
        let boxed = RemoteUnsafeTransfer(value: client)
        do {
            var buffer = try await boxed.value.executeCommand(command, maxResponseSize: 256 * 1024, mergeStreams: true)
            let output = buffer.readString(length: buffer.readableBytes) ?? ""
            try? await boxed.value.close()
            guard output.localizedCaseInsensitiveContains("joined") else {
                throw RemoteActionError.spawnNotConfirmed(output)
            }
            return output
        } catch {
            try? await boxed.value.close()
            throw error
        }
    }
}

private struct RemoteUnsafeTransfer<Value>: @unchecked Sendable { let value: Value }
