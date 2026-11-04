import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import PharosMeshCore

public struct SessionInventoryCollector: Sendable {
    public var codexDaemon: @Sendable () -> CodexDaemonClient?
    public var codexRolloutRoot: URL
    public var codexSessionIndexURL: URL
    public var decompressZstd: @Sendable (URL) -> Data?
    public var agyBin: String?
    public var acpRunner: (@Sendable (_ bin: String) throws -> [LightSessionEntry])?
    public var agyAppDataDir: URL
    public var cursorChatsDir: URL
    public var sqliteRunner: (@Sendable (_ dbPath: String) -> String?)?
    public var now: @Sendable () -> Date
    public var env: [String: String]

    public init(
        codexDaemon: @Sendable @escaping () -> CodexDaemonClient? = { CodexDaemonClient(socketPath: CodexDaemonClient.socketPath()) },
        codexRolloutRoot: URL = CodexRolloutReader().root,
        codexSessionIndexURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/session_index.jsonl"),
        decompressZstd: @Sendable @escaping (URL) -> Data? = { CodexRolloutReader.decompressZstd(fileURL: $0) },
        agyBin: String? = nil,
        acpRunner: (@Sendable (_ bin: String) throws -> [LightSessionEntry])? = nil,
        agyAppDataDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli"),
        cursorChatsDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/chats"),
        sqliteRunner: (@Sendable (_ dbPath: String) -> String?)? = nil,
        now: @Sendable @escaping () -> Date = Date.init,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.codexDaemon = codexDaemon
        self.codexRolloutRoot = codexRolloutRoot
        self.codexSessionIndexURL = codexSessionIndexURL
        self.decompressZstd = decompressZstd
        self.agyBin = agyBin
        self.acpRunner = acpRunner
        self.agyAppDataDir = agyAppDataDir
        self.cursorChatsDir = cursorChatsDir
        self.sqliteRunner = sqliteRunner
        self.now = now
        self.env = env
    }

    public func collect(node: String) -> LightNodeInventory {
        var allSessions: [LightSessionEntry] = []
        var notes: [String] = []

        // 1. Codex
        let (codexSessions, codexNote) = collectCodex()
        allSessions.append(contentsOf: codexSessions)
        if let codexNote {
            notes.append(codexNote)
        }

        // 2. Agy
        let (agySessions, agyNote) = collectAgy()
        allSessions.append(contentsOf: agySessions)
        if let agyNote {
            notes.append(agyNote)
        }

        // 3. Cursor
        let (cursorSessions, cursorNote) = collectCursor()
        allSessions.append(contentsOf: cursorSessions)
        if let cursorNote {
            notes.append(cursorNote)
        }

        // 4. dsh
        notes.append("dsh: not collected")

        return LightNodeInventory(node: node, at: now(), sessions: allSessions, notes: notes)
    }

    // MARK: - Codex Collection

    private func collectCodex() -> (sessions: [LightSessionEntry], note: String?) {
        if let client = codexDaemon() {
            do {
                var collected: [LightSessionEntry] = []
                var cursor: String? = nil

                while collected.count < 300 {
                    var params: [String: Any] = ["limit": 100, "archived": false]
                    if let cursor, !cursor.isEmpty {
                        params["cursor"] = cursor
                    }
                    let res = try client.call("thread/list", params)
                    let items = (res["threads"] as? [[String: Any]]) ?? (res["data"] as? [[String: Any]]) ?? []
                    for thread in items {
                        if thread["ephemeral"] as? Bool == true { continue }
                        if thread["archived"] as? Bool == true { continue }

                        guard let id = (thread["id"] as? String) ?? (thread["threadId"] as? String),
                              !id.isEmpty else { continue }
                        let cwd = thread["cwd"] as? String
                        let title = thread["name"] as? String // NEVER preview!
                        let source = thread["source"] as? String

                        let updatedAtVal = thread["updatedAt"] ?? thread["updated_at"]
                        let lastActive = Self.parseDate(updatedAtVal)

                        let state: String?
                        if let statusDict = thread["status"] as? [String: Any] {
                            let type = statusDict["type"] as? String ?? ""
                            let flags = (statusDict["activeFlags"] as? [String]) ?? []
                            if type == "waitingOnApproval" || type == "UserInput" || flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") {
                                state = "needs_human"
                            } else if type == "active" {
                                state = "active"
                            } else if type == "idle" {
                                state = "idle"
                            } else if type == "notLoaded" {
                                state = "notLoaded"
                            } else {
                                state = type.isEmpty ? "unknown" : type
                            }
                        } else if let statusStr = thread["status"] as? String {
                            if statusStr.contains("Approval") || statusStr.contains("UserInput") {
                                state = "needs_human"
                            } else {
                                state = statusStr
                            }
                        } else {
                            state = "unknown"
                        }

                        collected.append(LightSessionEntry(
                            app: "codex",
                            id: id,
                            cwd: cwd,
                            title: title,
                            lastActive: lastActive,
                            state: state,
                            source: source
                        ))
                    }

                    let next = (res["nextCursor"] as? String) ?? (res["cursor"] as? String)
                    if let next, !next.isEmpty, items.count > 0 {
                        cursor = next
                    } else {
                        break
                    }
                }

                let sorted = Array(collected.sorted(by: { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }).prefix(300))
                return (sorted, nil)
            } catch {
                // Fall back to rollout scan
            }
        }

        // Fallback: Rollouts
        return (collectCodexRollouts(), "codex: daemon not running, read rollouts")
    }

    private func collectCodexRollouts() -> [LightSessionEntry] {
        let scanDir: URL
        let sub = codexRolloutRoot.appendingPathComponent("sessions", isDirectory: true)
        if FileManager.default.fileExists(atPath: sub.path) {
            scanDir = sub
        } else {
            scanDir = codexRolloutRoot
        }

        guard let walker = FileManager.default.enumerator(
            at: scanDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        struct FileCandidate {
            let url: URL
            let mtime: Date
        }
        var files: [FileCandidate] = []

        for case let url as URL in walker {
            guard !url.pathComponents.contains("archived") && !url.pathComponents.contains("archived_sessions") else { continue }
            let name = url.lastPathComponent
            guard (name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")) ||
                  (name.hasPrefix("rollout-") && name.hasSuffix(".jsonl.zst")) else { continue }
            guard let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = resourceValues.contentModificationDate else { continue }
            files.append(FileCandidate(url: url, mtime: mtime))
        }

        files.sort(by: { $0.mtime > $1.mtime })
        let topFiles = files.prefix(300)

        // Read session_index.jsonl if available
        var threadNames: [String: String] = [:]
        if FileManager.default.fileExists(atPath: codexSessionIndexURL.path),
           let content = try? String(contentsOf: codexSessionIndexURL, encoding: .utf8) {
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let id = (obj["id"] as? String) ?? (obj["thread_id"] as? String),
                      let name = obj["thread_name"] as? String, !name.isEmpty else { continue }
                threadNames[id] = name
            }
        }

        var results: [LightSessionEntry] = []
        for file in topFiles {
            let firstLine: String?
            if file.url.pathExtension == "zst" {
                if let decomp = decompressZstd(file.url),
                   let str = String(data: decomp, encoding: .utf8) {
                    firstLine = str.components(separatedBy: "\n").first
                } else {
                    firstLine = nil
                }
            } else {
                guard let handle = try? FileHandle(forReadingFrom: file.url) else { continue }
                let chunk = handle.readData(ofLength: 8192)
                try? handle.close()
                firstLine = String(data: chunk, encoding: .utf8)?.components(separatedBy: "\n").first
            }

            guard let firstLine,
                  let lineData = firstLine.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                  json["type"] as? String == "session_meta",
                  let payload = json["payload"] as? [String: Any],
                  let id = payload["id"] as? String, !id.isEmpty else { continue }

            let source = (payload["source"] as? String) ?? (payload["originator"] as? String)
            if source == "exec" { continue }

            let cwd = payload["cwd"] as? String
            let title = threadNames[id]

            results.append(LightSessionEntry(
                app: "codex",
                id: id,
                cwd: cwd,
                title: title,
                lastActive: file.mtime,
                state: "notLoaded",
                source: source
            ))
        }

        return Array(results.sorted(by: { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }).prefix(300))
    }

    // MARK: - Agy Collection

    private func collectAgy() -> (sessions: [LightSessionEntry], note: String?) {
        // Try ACP
        if let runner = acpRunner {
            if let entries = try? runner(agyBin ?? "agy") {
                return (Array(entries.sorted(by: { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }).prefix(300)), nil)
            }
        } else {
            let bin = agyBin ?? CLIAgentDescriptor.agy(env: env).resolveBinary(env: env, isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
            if FileManager.default.isExecutableFile(atPath: bin) {
                if let entries = try? Self.queryACP(bin: bin, timeout: 15) {
                    return (Array(entries.sorted(by: { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }).prefix(300)), nil)
                }
            }
        }

        // Fallback: conversations/*.db + cache/conversation_metadata.json
        return (collectAgyMetadataFallback(), "agy: acp failed, read metadata cache")
    }

    public static func queryACP(bin: String, timeout: TimeInterval = 15) throws -> [LightSessionEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["acp"]

        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        let outFd = outPipe.fileHandleForReading.fileDescriptor
        var buffer = ""

        func readNextJSONLine() throws -> [String: Any]? {
            while Date() < deadline {
                if let newlineIdx = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[..<newlineIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                    buffer.removeSubrange(...newlineIdx)
                    if !line.isEmpty,
                       let data = line.data(using: .utf8),
                       let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        return obj
                    }
                    continue
                }

                var pfd = pollfd(fd: outFd, events: Int16(POLLIN), revents: 0)
                let remainingMs = Int32(max(10, deadline.timeIntervalSinceNow * 1000))
                #if canImport(Darwin)
                let ret = poll(&pfd, 1, remainingMs)
                #else
                let ret = poll(&pfd, 1, remainingMs)
                #endif
                if ret <= 0 { break }

                let chunk = outPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if let chunkStr = String(data: chunk, encoding: .utf8) {
                    buffer += chunkStr
                }
            }
            return nil
        }

        func sendLine(_ obj: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
            inPipe.fileHandleForWriting.write(data)
            inPipe.fileHandleForWriting.write(Data("\n".utf8))
        }

        // Step 1: initialize
        try sendLine(["id": 1, "method": "initialize", "params": ["protocolVersion": 1, "clientCapabilities": [String: Any]()]])
        var initOk = false
        while Date() < deadline {
            guard let obj = try readNextJSONLine() else { break }
            if obj["id"] as? Int == 1 {
                initOk = true
                break
            }
        }
        guard initOk else {
            throw NSError(domain: "PharosACP", code: 1, userInfo: [NSLocalizedDescriptionKey: "ACP initialize timed out"])
        }

        // Step 2: session/list
        var results: [LightSessionEntry] = []
        var nextCursor: String? = nil
        var reqId = 2

        while results.count < 300, Date() < deadline {
            var params: [String: Any] = [:]
            if let nextCursor, !nextCursor.isEmpty {
                params["cursor"] = nextCursor
            }
            try sendLine(["id": reqId, "method": "session/list", "params": params])

            var listResult: [String: Any]? = nil
            while Date() < deadline {
                guard let obj = try readNextJSONLine() else { break }
                if obj["id"] as? Int == reqId {
                    listResult = obj["result"] as? [String: Any]
                    break
                }
            }
            guard let listResult else { break }

            guard let sessions = listResult["sessions"] as? [[String: Any]] else { break }
            for s in sessions {
                guard let sid = (s["sessionId"] as? String) ?? (s["id"] as? String), !sid.isEmpty else { continue }
                let rawCwd = s["cwd"] as? String
                let cleanCwd = rawCwd?.removingPercentEncoding ?? rawCwd
                let title = s["title"] as? String
                let updatedAt = parseDate(s["updatedAt"] ?? s["updated_at"])

                results.append(LightSessionEntry(
                    app: "agy",
                    id: sid,
                    cwd: cleanCwd,
                    title: title,
                    lastActive: updatedAt,
                    state: "unknown",
                    source: "cli"
                ))
            }

            if let cursor = (listResult["nextCursor"] as? String) ?? (listResult["cursor"] as? String),
               !cursor.isEmpty, sessions.count > 0 {
                nextCursor = cursor
                reqId += 1
            } else {
                break
            }
        }

        return results
    }

    private func collectAgyMetadataFallback() -> [LightSessionEntry] {
        let convDir = agyAppDataDir.appendingPathComponent("conversations", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: convDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var sessionIDs: [String] = []
        for file in files where file.pathExtension == "db" {
            let id = file.deletingPathExtension().lastPathComponent
            if !id.isEmpty {
                sessionIDs.append(id)
            }
        }

        // Load conversation_metadata.json
        let metaURL = agyAppDataDir.appendingPathComponent("cache/conversation_metadata.json")
        var metadataDict: [String: [String: Any]] = [:]
        if let data = try? Data(contentsOf: metaURL),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let convs = obj["conversations"] as? [String: [String: Any]] {
            metadataDict = convs
        }

        // Load last_conversations.json for cwd
        let lastConvURL = agyAppDataDir.appendingPathComponent("cache/last_conversations.json")
        var sessionToCwd: [String: String] = [:]
        if let data = try? Data(contentsOf: lastConvURL),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
            for (k, v) in obj {
                if k.hasPrefix("/") || k.contains("/") {
                    sessionToCwd[v] = k
                } else {
                    sessionToCwd[k] = v
                }
            }
        }

        var results: [LightSessionEntry] = []
        for id in sessionIDs {
            let meta = metadataDict[id]
            if let isInternal = meta?["is_internal"] as? Bool, isInternal { continue }
            if let archived = meta?["archived"] as? Bool, archived { continue }
            if let hidden = meta?["hidden"] as? Bool, hidden { continue }

            var title: String? = nil
            if let summary = meta?["summary"] as? [String: Any] {
                title = summary["Title"] as? String // NEVER Preview!
            }

            let lastActive = Self.parseDate(meta?["last_modified_time"] ?? meta?["updatedAt"])
            let cwd = sessionToCwd[id]

            results.append(LightSessionEntry(
                app: "agy",
                id: id,
                cwd: cwd,
                title: title,
                lastActive: lastActive,
                state: "unknown",
                source: "cli"
            ))
        }

        return Array(results.sorted(by: { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }).prefix(300))
    }

    // MARK: - Cursor Collection

    private func collectCursor() -> (sessions: [LightSessionEntry], note: String?) {
        guard FileManager.default.fileExists(atPath: cursorChatsDir.path) else {
            return ([], "cursor: not collected")
        }

        guard let walker = FileManager.default.enumerator(
            at: cursorChatsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], "cursor: not collected")
        }

        var entries: [LightSessionEntry] = []
        for case let url as URL in walker {
            guard url.lastPathComponent == "store.db" else { continue }
            let chatDir = url.deletingLastPathComponent()
            let id = chatDir.lastPathComponent
            guard !id.isEmpty else { continue }

            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

            var title: String? = nil
            if let runner = sqliteRunner {
                title = runner(url.path)
            } else if FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") {
                title = Self.readCursorTitle(dbPath: url.path)
            }

            entries.append(LightSessionEntry(
                app: "cursor",
                id: id,
                cwd: nil,
                title: title,
                lastActive: mtime,
                state: "unknown",
                source: "vscode"
            ))
        }

        if entries.isEmpty {
            return ([], "cursor: not collected")
        }

        let sorted = Array(entries.sorted(by: { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }).prefix(300))
        return (sorted, nil)
    }

    private static func readCursorTitle(dbPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", dbPath, "select value from meta where key='0'"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(3.0)
            while process.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if process.isRunning {
                process.terminate()
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty, var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return nil
            }
            // Check if hex-encoded
            if text.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) && text.count % 2 == 0 {
                var hexData = Data()
                var idx = text.startIndex
                while idx < text.endIndex {
                    let nextIdx = text.index(idx, offsetBy: 2)
                    let byteStr = String(text[idx..<nextIdx])
                    if let byte = UInt8(byteStr, radix: 16) {
                        hexData.append(byte)
                    }
                    idx = nextIdx
                }
                if let decoded = String(data: hexData, encoding: .utf8) {
                    text = decoded
                }
            }
            if let d = text.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               let name = obj["name"] as? String, !name.isEmpty {
                return name
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    public static func parseDate(_ val: Any?) -> Date? {
        guard let val else { return nil }
        if let d = val as? Double {
            return d > 10_000_000_000 ? Date(timeIntervalSince1970: d / 1000.0) : Date(timeIntervalSince1970: d)
        }
        if let i = val as? Int {
            let d = Double(i)
            return d > 10_000_000_000 ? Date(timeIntervalSince1970: d / 1000.0) : Date(timeIntervalSince1970: d)
        }
        if let str = val as? String {
            if let num = Double(str) {
                return num > 10_000_000_000 ? Date(timeIntervalSince1970: num / 1000.0) : Date(timeIntervalSince1970: num)
            }
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: str) {
                return date
            }
            let isoFrac = ISO8601DateFormatter()
            isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = isoFrac.date(from: str) {
                return date
            }
        }
        return nil
    }
}
