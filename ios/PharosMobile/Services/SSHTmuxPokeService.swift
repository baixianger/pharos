import Citadel
import Crypto
import Foundation
import NIOCore

enum TmuxPokeError: LocalizedError {
    case unsafeValue(String)
    case missingHost
    case unverifiedHostKey
    case missingIdentity

    var errorDescription: String? {
        switch self {
        case .unsafeValue(let value): "Unsafe tmux/agent value: \(value)"
        case .missingHost: "No SSH host mapping exists for this agent's machine."
        case .unverifiedHostKey: "Confirm the SSH host-key risk in Settings before poking."
        case .missingIdentity: "Choose a device-local SSH identity for this host."
        }
    }
}

enum TmuxPokeCommand {
    static func build(nick: String, memberID: String, pane paneID: String,
                      socket: String? = nil, kind: String?) throws -> String {
        guard isSafeIdentity(nick) else { throw TmuxPokeError.unsafeValue(nick) }
        guard isSafeIdentity(memberID) else { throw TmuxPokeError.unsafeValue(memberID) }
        let paneDigits = paneID.first == "%" ? paneID.dropFirst() : Substring(paneID)
        guard !paneDigits.isEmpty, paneDigits.allSatisfy(\.isNumber) else {
            throw TmuxPokeError.unsafeValue(paneID)
        }
        if let socket, !isSafeSocket(socket) { throw TmuxPokeError.unsafeValue(socket) }
        let tmux = socket.map { "tmux -S '\($0)'" } ?? "tmux"
        let expected = kind == "codex" ? "codex" : "claude|node|bun|[0-9]+\\.[0-9]+\\.[0-9]+"
        let message = "You have new mesh messages. Run: pharos mesh recv \(nick) --member \(memberID)"
        return """
        export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH
        c=$(\(tmux) display-message -p -t '\(paneID)' '#{pane_current_command}' 2>/dev/null) || exit 31
        printf '%s' "$c" | grep -Eq '^(\(expected))$' || exit 32
        view=$(\(tmux) capture-pane -p -t '\(paneID)' 2>/dev/null) || exit 33
        printf '%s' "$view" | grep -Eqi 'esc to interrupt|working|do you want to proceed|enter to confirm|esc to cancel' && exit 34
        printf '%s' "$view" | grep -Eq '❯|›' || exit 35
        \(tmux) send-keys -t '\(paneID)' -l -- '\(message)'
        sleep 0.35
        \(tmux) send-keys -t '\(paneID)' Enter
        printf 'POKED'
        """
    }

    private static func isSafeIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }

    private static func isSafeSocket(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("'") && !value.contains("\n") && !value.contains("\r")
    }
}

actor SSHTmuxPokeService {
    func poke(member: MeshMember, profile: SSHHostProfile, privateKey: Curve25519.Signing.PrivateKey) async throws {
        guard profile.acceptsUnverifiedHostKey else { throw TmuxPokeError.unverifiedHostKey }
        guard let pane = member.tmuxPane else { throw TmuxPokeError.unsafeValue("missing pane") }
        let command = try TmuxPokeCommand.build(nick: member.nick, memberID: member.id, pane: pane,
                                                socket: member.tmuxSocket, kind: member.kind)
        let client = try await SSHClient.connect(
            host: profile.sshHost,
            port: Int(profile.port),
            authenticationMethod: .ed25519(username: profile.username, privateKey: privateKey),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        do {
            _ = try await client.executeCommand(command, maxResponseSize: 64 * 1024, mergeStreams: true)
            try? await client.close()
        } catch {
            try? await client.close()
            throw error
        }
    }
}
