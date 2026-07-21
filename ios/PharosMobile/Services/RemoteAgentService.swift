import Citadel
import Crypto
import Foundation
import PharosMeshProtocol

enum RemoteActionError: LocalizedError {
    case unsafeValue(String)
    case unverifiedHostKey
    case missingIdentity
    case spawnNotConfirmed(String)
    case keyInstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsafeValue(let value): "Unsafe remote value: \(value)"
        case .unverifiedHostKey: "Confirm the SSH host-key risk in Settings first."
        case .missingIdentity: "Choose a device-local SSH identity for this host."
        case .spawnNotConfirmed(let output): "The remote spawn did not confirm that it joined. \(output)"
        case .keyInstallFailed(let output): "The host did not confirm the key was installed. \(output)"
        }
    }
}

/// Outcome of installing this device's public key on a host.
enum KeyInstallOutcome: Sendable { case added, alreadyPresent }

enum MobileAgentKind: String, CaseIterable, Identifiable, Sendable {
    case claude, codex
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Where a spawned agent should start. Resolved on the target host: `.project`
/// maps to that host's own registered checkout path; `.path` is used literally.
enum SpawnWorkDir: Equatable, Sendable {
    case scratch
    case project(String)
    case path(String)
}

/// A project as reported by `pharos list --json` on the target host.
struct RemoteProject: Identifiable, Sendable, Hashable {
    var id: String { replicaID ?? name }
    let name: String
    let localPath: String?
    let githubRemote: String?
    let tags: [String]
    var notes: String = ""
    var yolo: Bool = true
    var tmux: Bool = false
    var playbooks: [RemotePlaybook] = []
    var milestones: [RemoteMilestone] = []
    var issues: [RemoteIssue] = []
    var updates: [RemoteProjectUpdate] = []
    /// Stable replicated entity identity. Legacy Broker payloads leave this
    /// nil and retain the historical name-derived identity.
    var replicaID: String? = nil
    var hasLocalPath: Bool { localPath != nil }
}

typealias RemotePlaybook = MeshProjectPlaybook
typealias RemoteMilestone = MeshProjectMilestone

struct RemoteProjectUpdate: Identifiable, Sendable, Hashable {
    let id: String
    let body: String
    let kind: String
    let issueNumber: Int?
}

/// One issue aggregated from `pharos issue list <project> --json` across projects.
struct RemoteIssue: Identifiable, Sendable, Hashable {
    var id: String { replicaID ?? "\(project)#\(number)" }
    let project: String
    let number: Int
    let title: String
    let status: String
    let priority: String
    let labels: [String]
    var body: String = ""
    var activeSession: String? = nil
    /// Manual board ordering set on the desktop; nil when unspecified. Carried
    /// so the iOS list can honor the same ordering within a status group.
    var sortOrder: Double? = nil
    var milestoneID: String? = nil
    var parent: Int? = nil
    var relations: [RemoteIssueRelation] = []
    var attachments: [RemoteIssueAttachment] = []
    /// Stable replicated entity identity. This prevents two offline devices
    /// that choose the same display number from overwriting one another.
    var replicaID: String? = nil
}

typealias RemoteIssueRelation = MeshIssueRelationValue
typealias RemoteIssueAttachment = MeshIssueAttachmentValue

struct PendingRemoteAttachment: Identifiable, Sendable {
    let id: UUID
    let data: Data
    let name: String
    let mediaType: String
    let isImage: Bool
}

enum RemoteCommandBuilder {
    static let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    static func spawn(room: String, nick: String, kind: MobileAgentKind,
                      workDir: SpawnWorkDir = .scratch) throws -> String {
        guard safe(room) else { throw RemoteActionError.unsafeValue(room) }
        guard safe(nick) else { throw RemoteActionError.unsafeValue(nick) }
        var command = "export PATH=\(path):$PATH; pharos mesh spawn \(room) \(nick) \(kind.rawValue)"
        switch workDir {
        case .scratch:
            break
        case .project(let raw):
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard shellSafe(name) else { throw RemoteActionError.unsafeValue(name) }
            command += " --project \(singleQuoted(name))"
        case .path(let raw):
            let dir = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard shellSafe(dir), dir.hasPrefix("/") || dir.hasPrefix("~") else {
                throw RemoteActionError.unsafeValue(dir)
            }
            command += " --cwd \(singleQuoted(dir))"
        }
        return command
    }

    /// Command to enumerate the target host's registered projects.
    static func listProjects() -> String {
        "export PATH=\(path):$PATH; pharos list --json"
    }

    /// Aggregate every registered project's open issues into one JSON blob. Runs
    /// a small Python driver on the host (read from stdin, so no shell quoting)
    /// that walks `pharos list` and calls `pharos issue list <name> --json`.
    static func listIssues() -> String {
        let py = """
        import json, subprocess
        def run(a):
            try: return json.loads(subprocess.run(a, capture_output=True, text=True, timeout=20).stdout)
            except Exception: return {}
        projs = run(['pharos','list','--json']).get('projects', [])
        out = []
        for p in projs:
            name = p.get('name')
            if not name: continue
            for it in run(['pharos','issue','list',name,'--json']).get('issues', []):
                out.append({'project': name, 'number': it.get('number'), 'title': it.get('title',''),
                            'status': it.get('status',''), 'priority': it.get('priority',''),
                            'labels': it.get('labels', [])})
        print(json.dumps({'issues': out}))
        """
        return "export PATH=\(path):$PATH; python3 - <<'PHAROS_PY'\n\(py)\nPHAROS_PY"
    }

    /// Safe to place inside single quotes: no quote/newline that could break out.
    private static func shellSafe(_ v: String) -> Bool {
        !v.isEmpty && !v.contains("'") && !v.contains("\n") && !v.contains("\r")
    }

    private static func singleQuoted(_ v: String) -> String { "'\(v)'" }

    static func attach(pane: String, socket: String? = nil) throws -> String {
        let digits = pane.first == "%" ? pane.dropFirst() : Substring(pane)
        guard pane.first == "%", !digits.isEmpty, digits.allSatisfy(\.isNumber) else {
            throw RemoteActionError.unsafeValue(pane)
        }
        if let socket, !shellSafe(socket) || !socket.hasPrefix("/") {
            throw RemoteActionError.unsafeValue(socket)
        }
        let tmux = socket.map { "tmux -S \(singleQuoted($0))" } ?? "tmux"
        // `-d` detaches any other client on attach so THIS terminal is the only
        // one driving the window size. Two clients of different sizes make tmux
        // fight over the smallest size and redraw continuously (the "flushing"
        // screen); a single client renders at one stable size.
        return "export PATH=\(path):$PATH; s=$(\(tmux) display-message -p -t '\(pane)' '#{session_name}') || exit 31; exec \(tmux) attach-session -d -t \"=$s\""
    }

    private static func safe(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }
}

actor RemoteAgentService {
    /// `ssh-copy-id` for the phone: log in once with a password, append this
    /// device's public key to the host's `~/.ssh/authorized_keys` (idempotent,
    /// with the right perms), then prove it worked by reconnecting with the
    /// key. The password is used only for this call and never stored.
    func installAuthorizedKey(publicKeyOpenSSH: String, host: String, port: UInt16,
                              username: String, password: String,
                              privateKey: Curve25519.Signing.PrivateKey) async throws -> KeyInstallOutcome {
        let key = publicKeyOpenSSH.trimmingCharacters(in: .whitespacesAndNewlines)
        // The key line is `ssh-ed25519 <base64> <comment>` — no single quotes.
        // Refuse anything unexpected so it can't break out of the shell quoting.
        guard key.hasPrefix("ssh-"), !key.contains("'"), !key.contains("\n") else {
            throw RemoteActionError.unsafeValue("public key")
        }
        let script = """
        set -e; umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; \
        chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys; \
        if grep -qxF '\(key)' ~/.ssh/authorized_keys; then echo PHAROS_ALREADY; \
        else printf '%s\\n' '\(key)' >> ~/.ssh/authorized_keys; echo PHAROS_ADDED; fi
        """
        // 1. Password login + append.
        let pwClient = try await SSHClient.connect(
            host: host, port: Int(port),
            authenticationMethod: .passwordBased(username: username, password: password),
            hostKeyValidator: .acceptAnything(), reconnect: .never
        )
        let boxedPw = RemoteUnsafeTransfer(value: pwClient)
        let output: String
        do {
            var buffer = try await boxedPw.value.executeCommand(script, maxResponseSize: 64 * 1024, mergeStreams: true)
            output = (buffer.readString(length: buffer.readableBytes) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            try? await boxedPw.value.close()
        } catch {
            try? await boxedPw.value.close()
            throw error
        }
        guard output.contains("PHAROS_ADDED") || output.contains("PHAROS_ALREADY") else {
            throw RemoteActionError.keyInstallFailed(output)
        }
        // 2. Verify by reconnecting with the key — proves authorized_keys works.
        let keyClient = try await SSHClient.connect(
            host: host, port: Int(port),
            authenticationMethod: .ed25519(username: username, privateKey: privateKey),
            hostKeyValidator: .acceptAnything(), reconnect: .never
        )
        try? await RemoteUnsafeTransfer(value: keyClient).value.close()
        return output.contains("PHAROS_ADDED") ? .added : .alreadyPresent
    }

    /// Enumerate the projects registered on `profile`'s host (via `pharos list
    /// --json`) so the spawn UI can offer a directory picker.
    func listProjects(profile: SSHHostProfile,
                      privateKey: Curve25519.Signing.PrivateKey) async throws -> [RemoteProject] {
        guard profile.acceptsUnverifiedHostKey else { throw RemoteActionError.unverifiedHostKey }
        let client = try await SSHClient.connect(
            host: profile.sshHost, port: Int(profile.port),
            authenticationMethod: .ed25519(username: profile.username, privateKey: privateKey),
            hostKeyValidator: .acceptAnything(), reconnect: .never
        )
        let boxed = RemoteUnsafeTransfer(value: client)
        do {
            var buffer = try await boxed.value.executeCommand(RemoteCommandBuilder.listProjects(),
                                                              maxResponseSize: 512 * 1024, mergeStreams: true)
            let output = buffer.readString(length: buffer.readableBytes) ?? ""
            try? await boxed.value.close()
            return Self.parseProjects(output)
        } catch {
            try? await boxed.value.close()
            throw error
        }
    }

    nonisolated static func parseProjects(_ raw: String) -> [RemoteProject] {
        guard let obj = firstJSONObject(raw), let arr = obj["projects"] as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            guard let name = (dict["name"] as? String), !name.isEmpty else { return nil }
            let issues = ((dict["issues"] as? [[String: Any]]) ?? []).compactMap { issue -> RemoteIssue? in
                guard let number = issue["number"] as? Int,
                      let title = issue["title"] as? String else { return nil }
                return RemoteIssue(project: name, number: number, title: title,
                                   status: issue["status"] as? String ?? "todo",
                                   priority: issue["priority"] as? String ?? "none",
                                   labels: issue["labels"] as? [String] ?? [],
                                   body: issue["body"] as? String ?? "",
                                   activeSession: issue["activeSession"] as? String)
            }
            let updates = ((dict["updates"] as? [[String: Any]]) ?? []).compactMap { update -> RemoteProjectUpdate? in
                guard let body = update["body"] as? String, !body.isEmpty else { return nil }
                return RemoteProjectUpdate(id: update["id"] as? String ?? UUID().uuidString,
                                           body: body,
                                           kind: update["kind"] as? String ?? "note",
                                           issueNumber: update["issueNumber"] as? Int)
            }
            return RemoteProject(name: name,
                                 localPath: dict["localPath"] as? String,
                                 githubRemote: dict["githubRemote"] as? String,
                                 tags: (dict["tags"] as? [String]) ?? [],
                                 notes: dict["notes"] as? String ?? "",
                                 issues: issues,
                                 updates: updates)
        }
    }

    nonisolated static func parseIssues(_ raw: String) -> [RemoteIssue] {
        guard let obj = firstJSONObject(raw), let arr = obj["issues"] as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            guard let project = dict["project"] as? String,
                  let number = dict["number"] as? Int,
                  let title = dict["title"] as? String else { return nil }
            return RemoteIssue(project: project, number: number, title: title,
                               status: dict["status"] as? String ?? "",
                               priority: dict["priority"] as? String ?? "",
                               labels: (dict["labels"] as? [String]) ?? [],
                               body: dict["body"] as? String ?? "",
                               activeSession: (dict["activeSession"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               sortOrder: (dict["sortOrder"] as? Double) ?? (dict["sortOrder"] as? Int).map(Double.init))
        }
    }

    /// Parse the first top-level JSON object in a string, tolerating leading noise.
    private nonisolated static func firstJSONObject(_ raw: String) -> [String: Any]? {
        guard let start = raw.firstIndex(of: "{"),
              let data = String(raw[start...]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Fetch aggregated issues from `profile`'s host.
    func listIssues(profile: SSHHostProfile,
                    privateKey: Curve25519.Signing.PrivateKey) async throws -> [RemoteIssue] {
        guard profile.acceptsUnverifiedHostKey else { throw RemoteActionError.unverifiedHostKey }
        let client = try await SSHClient.connect(
            host: profile.sshHost, port: Int(profile.port),
            authenticationMethod: .ed25519(username: profile.username, privateKey: privateKey),
            hostKeyValidator: .acceptAnything(), reconnect: .never
        )
        let boxed = RemoteUnsafeTransfer(value: client)
        do {
            var buffer = try await boxed.value.executeCommand(RemoteCommandBuilder.listIssues(),
                                                              maxResponseSize: 1024 * 1024, mergeStreams: true)
            let output = buffer.readString(length: buffer.readableBytes) ?? ""
            try? await boxed.value.close()
            return Self.parseIssues(output)
        } catch {
            try? await boxed.value.close()
            throw error
        }
    }

    func spawn(room: String, nick: String, kind: MobileAgentKind, profile: SSHHostProfile,
               privateKey: Curve25519.Signing.PrivateKey,
               workDir: SpawnWorkDir = .scratch) async throws -> String {
        guard profile.acceptsUnverifiedHostKey else { throw RemoteActionError.unverifiedHostKey }
        let command = try RemoteCommandBuilder.spawn(room: room, nick: nick, kind: kind, workDir: workDir)
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
