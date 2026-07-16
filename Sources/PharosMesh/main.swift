import Foundation
import PharosMeshCore

@main
enum PharosMeshMain {
    static func main() {
        exit(MeshHeadlessCLI.run(Array(CommandLine.arguments.dropFirst())))
    }
}

private enum MeshHeadlessCLI {
    static func run(_ args: [String]) -> Int32 {
        guard let command = args.first else {
            print(usage)
            return 2
        }
        if let endpoint = option("--endpoint", in: args) {
            guard meshSplitHostPort(endpoint) != nil else {
                return usageError("--endpoint HOST:PORT")
            }
            MeshClient.remoteEndpoint = endpoint
        }

        switch command {
        case "serve", "daemon":
            configureServer(Array(args.dropFirst()))
            MeshBroker.runDaemon()

        case "capabilities":
            return printResponse(MeshClient.send(MeshRequest(cmd: "capabilities")))

        case "pair":
            guard let endpoint = option("--endpoint", in: args),
                  meshSplitHostPort(endpoint) != nil else {
                return usageError("pair --endpoint HOST:PORT")
            }
            let response = MeshClient.send(MeshRequest(cmd: "pairing-create",
                                                       timeoutMs: 300_000, host: endpoint),
                                           to: endpoint)
            guard response.ok, let link = response.payload else { return printResponse(response) }
            printTerminalQRCode(link)
            print(link)
            print("expires in 5 minutes · single use")
            return 0

        case "create":
            guard args.count >= 2 else { return usageError("create <room>") }
            return printResponse(MeshClient.send(MeshRequest(cmd: "create", room: args[1])))

        case "list":
            let response = MeshClient.send(MeshRequest(cmd: "list"))
            guard response.ok else { return printResponse(response) }
            for room in response.rooms ?? [] {
                print("\(room.name)\t\(room.members.joined(separator: ","))")
            }
            return 0

        case "history":
            guard args.count >= 2 else { return usageError("history <room> [--limit N]") }
            let limit = option("--limit", in: args).flatMap(Int.init) ?? 30
            let response = MeshClient.send(MeshRequest(cmd: "history", room: args[1], limit: limit))
            guard response.ok else { return printResponse(response) }
            printMessages(response.messages ?? [])
            return 0

        case "join":
            guard args.count >= 3, let session = option("--session", in: args), !session.isEmpty else {
                return usageError("join <room> <nick> --session <id> [--kind codex|claude]")
            }
            var request = MeshRequest(cmd: "join", room: args[1], nick: args[2])
            request.session = session
            request.memberID = session
            request.project = FileManager.default.currentDirectoryPath
            request.host = ProcessInfo.processInfo.hostName
            request.kind = option("--kind", in: args)
            let response = MeshClient.send(request)
            guard response.ok else { return printResponse(response) }
            print("joined \(args[1]) as \(args[2])")
            printMessages(response.messages ?? [])
            return 0

        case "say":
            guard args.count >= 4 else { return usageError("say <room> <nick> <text> [--reply ID] [--attach FILE]") }
            var request = MeshRequest(cmd: "say", room: args[1], nick: args[2], text: args[3])
            request.to = mentions(in: args[3])
            request.replyToID = option("--reply", in: args)
            if request.replyToID != nil || option("--attach", in: args) != nil {
                let capabilities = MeshClient.send(MeshRequest(cmd: "capabilities"))
                guard capabilities.capabilities?.contains("mesh-v2") == true else {
                    FileHandle.standardError.write(Data("error: broker does not support replies or attachments\n".utf8))
                    return 1
                }
            }
            if let path = option("--attach", in: args) {
                do {
                    request.attachments = [try MeshClient.uploadAttachment(fileAt: URL(fileURLWithPath: path))]
                } catch {
                    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                    return 1
                }
            }
            return printResponse(MeshClient.send(request))

        case "recv":
            guard args.count >= 2 else { return usageError("recv <nick> [--member <session-id>]") }
            var request = MeshRequest(cmd: "recv", nick: args[1])
            request.memberID = option("--member", in: args)
            request.project = FileManager.default.currentDirectoryPath
            let response = MeshClient.send(request)
            guard response.ok else { return printResponse(response) }
            printMessages(response.messages ?? [])
            return 0

        case "attachment":
            return runAttachment(Array(args.dropFirst()))

        case "registry":
            return runRegistry(Array(args.dropFirst()))

        case "--help", "-h", "help":
            print(usage)
            return 0

        case "--version", "version":
            print("pharos-mesh 0.8.0")
            return 0

        default:
            return usageError(command)
        }
    }

    private static func runAttachment(_ args: [String]) -> Int32 {
        guard let command = args.first else { return usageError("attachment put|get …") }
        switch command {
        case "put":
            guard args.count >= 2 else { return usageError("attachment put <file>") }
            let url = URL(fileURLWithPath: args[1]).standardizedFileURL
            do {
                let attachment = try MeshClient.uploadAttachment(
                    fileAt: url, id: option("--id", in: args), name: option("--name", in: args))
                print(attachment.id)
                return 0
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                return 1
            }
        case "get":
            guard args.count >= 2 else { return usageError("attachment get <id> [--out path]") }
            let output = option("--out", in: args).map(URL.init(fileURLWithPath:))
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(args[1])
            do {
                let result = try MeshClient.downloadAttachment(id: args[1], to: output)
                print(result.path)
                return 0
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                return 1
            }
        default:
            return usageError("attachment put|get …")
        }
    }

    private static func runRegistry(_ args: [String]) -> Int32 {
        guard let command = args.first else { return usageError("registry get|import …") }
        do {
            switch command {
            case "get":
                let snapshot = try MeshClient.fetchRegistry()
                if let destination = option("--output", in: args) {
                    try Data(snapshot.payload.utf8).write(to: URL(fileURLWithPath: destination), options: .atomic)
                } else {
                    print(snapshot.payload)
                }
                FileHandle.standardError.write(Data("revision \(snapshot.revision)\n".utf8))
                return 0
            case "import":
                guard args.count >= 2, let expected = option("--expected", in: args) else {
                    return usageError("registry import <projects.json> --expected REVISION")
                }
                let payload = try String(contentsOfFile: args[1], encoding: .utf8)
                let revision = try MeshClient.replaceRegistry(payload: payload, expectedRevision: expected)
                print(revision)
                return 0
            default:
                return usageError("registry get|import …")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func configureServer(_ args: [String]) {
        var environment = ProcessInfo.processInfo.environment
        if let bind = option("--bind", in: args) {
            environment["PHAROS_MESH_TCP"] = bind
            environment["PHAROS_MESH_TCP_INSECURE"] = "1"
        }
        if let directory = option("--data-dir", in: args) {
            environment["PHAROS_MESH_DIR"] = directory
            environment["PHAROS_MESH_DATA_DIR"] = directory
        }
        for (key, value) in environment { setenv(key, value, 1) }
    }

    private static func option(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func mentions(in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9._-])@([A-Za-z0-9._-]+)"#) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let values = expression.matches(in: text, range: range).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        return values.isEmpty ? nil : Array(Set(values)).sorted()
    }

    private static func printMessages(_ messages: [MeshMsg]) {
        if messages.isEmpty { print("(no messages)") }
        for message in messages {
            print("id: \(message.stableID)")
            if let reply = message.replyTo {
                print("  ↳ \(reply.from): \(reply.preview)")
            }
            print("[\(message.room)] \(message.from): \(message.text)")
            for attachment in message.attachments ?? [] {
                print("  attachment: \(attachment.name) (\(attachment.byteSize) bytes, id \(attachment.id))")
                print("  download: pharos-mesh attachment get \(attachment.id) --out \(attachment.name)")
            }
        }
    }

    private static func printResponse(_ response: MeshResponse) -> Int32 {
        if response.ok {
            if let capabilities = response.capabilities { print(capabilities.joined(separator: "\n")) }
            else if let note = response.note { print(note) }
            else { print("ok") }
            return 0
        }
        FileHandle.standardError.write(Data("error: \(response.error ?? "unknown error")\n".utf8))
        return 1
    }

    private static func printTerminalQRCode(_ value: String) {
        let candidates = ["/opt/homebrew/bin/qrencode", "/usr/local/bin/qrencode", "/usr/bin/qrencode"]
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-t", "ANSIUTF8", value]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try? process.run()
        process.waitUntilExit()
    }

    private static func usageError(_ detail: String) -> Int32 {
        FileHandle.standardError.write(Data("usage: pharos-mesh \(detail)\n".utf8))
        return 2
    }

    private static let usage = """
    pharos-mesh — headless Pharos Mesh broker and client

      serve [--bind HOST:PORT] [--data-dir PATH]
      capabilities [--endpoint HOST:PORT]
      pair --endpoint HOST:PORT
      create <room>
      list
      history <room> [--limit N]
      join <room> <nick> --session <id> [--kind codex|claude]
      say <room> <nick> <text> [--reply ID] [--attach FILE]
      recv <nick> [--member <session-id>]
      attachment put <file> [--id UUID] [--name DISPLAY-NAME]
      attachment get <id> [--out PATH]
      registry get [--output PATH]
      registry import <projects.json> --expected REVISION

    Add `--endpoint HOST:PORT` to any client command to dial a remote broker.
    """
}
