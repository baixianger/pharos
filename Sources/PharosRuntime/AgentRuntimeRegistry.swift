import Foundation

final class AgentRuntimeRegistry: @unchecked Sendable {
    enum RegistryError: LocalizedError {
        case invalidParams(String)
        case notFound(String)
        case unsupportedMethod(String)

        var errorDescription: String? {
            switch self {
            case .invalidParams(let value): "Invalid params: \(value)"
            case .notFound(let value): value
            case .unsupportedMethod(let value): "Method not found: \(value)"
            }
        }
    }

    private let lock = NSLock()
    private var snapshot: AgentRuntimeSnapshot

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: AgentRuntimePaths.registry),
           let value = try? decoder.decode(AgentRuntimeSnapshot.self, from: data),
           value.protocolVersion == AgentRuntimeProtocol.version {
            snapshot = value
        } else {
            snapshot = AgentRuntimeSnapshot()
        }
    }

    func invoke(method: String, params: [String: Any]) throws -> Any {
        lock.lock()
        defer { lock.unlock() }

        switch method {
        case "runtime.hello":
            return [
                "service": AgentRuntimeProtocol.service,
                "protocolVersion": AgentRuntimeProtocol.version,
                "capabilities": [
                    "driver-registration-v1", "conversation-registry-v1",
                    "surface-attachment-v1", "delivery-queue-v1",
                ],
            ]

        case "runtime.snapshot":
            return try object(snapshot)

        case "events.cursor":
            return AgentRuntimeEventJournal.shared.cursorObject()

        case "events.resume":
            let cursor = (params["cursor"] as? NSNumber)?.uint64Value ?? 0
            return AgentRuntimeEventJournal.shared.resumeObject(after: cursor)

        case "codex.status":
            return CodexAppServerDriver.shared.status()

        case "codex.thread.list":
            return try CodexAppServerDriver.shared.request(method: "thread/list", params: params)

        case "codex.thread.read":
            return try CodexAppServerDriver.shared.request(method: "thread/read", params: params)

        case "codex.thread.start":
            return try CodexAppServerDriver.shared.request(method: "thread/start", params: params)

        case "codex.thread.resume":
            return try CodexAppServerDriver.shared.request(method: "thread/resume", params: params)

        case "codex.thread.fork":
            return try CodexAppServerDriver.shared.request(method: "thread/fork", params: params)

        case "codex.turn.start":
            return try CodexAppServerDriver.shared.request(method: "turn/start", params: params)

        case "codex.turn.interrupt":
            return try CodexAppServerDriver.shared.request(method: "turn/interrupt", params: params)

        case "driver.register":
            let driverID = try required("driverID", params)
            let now = Date()
            let record = AgentRuntimeDriverRecord(
                id: driverID,
                kind: try required("kind", params),
                version: params["version"] as? String,
                capabilities: params["capabilities"] as? [String] ?? [],
                processID: (params["processID"] as? NSNumber)?.int32Value,
                connectedAt: snapshot.drivers.first(where: { $0.id == driverID })?.connectedAt ?? now,
                lastSeenAt: now
            )
            upsert(record, in: &snapshot.drivers)
            try persist()
            return try object(record)

        case "driver.heartbeat":
            let driverID = try required("driverID", params)
            guard let index = snapshot.drivers.firstIndex(where: { $0.id == driverID }) else {
                throw RegistryError.notFound("Unknown driver: \(driverID)")
            }
            snapshot.drivers[index].lastSeenAt = Date()
            try persist()
            return try object(snapshot.drivers[index])

        case "conversation.register":
            let driverID = try required("driverID", params)
            guard snapshot.drivers.contains(where: { $0.id == driverID }) else {
                throw RegistryError.notFound("Register driver before its conversations: \(driverID)")
            }
            let vendorSessionID = try required("vendorSessionID", params)
            let kind = try required("kind", params)
            let now = Date()
            let existing = snapshot.conversations.first {
                $0.kind == kind && $0.vendorSessionID == vendorSessionID
            }
            let ownership = (params["ownership"] as? String)
                .flatMap(AgentRuntimeOwnership.init(rawValue:)) ?? .attached
            let record = AgentConversationRecord(
                id: existing?.id ?? UUID().uuidString.lowercased(),
                driverID: driverID,
                vendorSessionID: vendorSessionID,
                kind: kind,
                title: params["title"] as? String ?? existing?.title,
                projectPath: params["projectPath"] as? String ?? existing?.projectPath,
                memberID: params["memberID"] as? String ?? existing?.memberID,
                ownership: ownership,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
            upsert(record, in: &snapshot.conversations)
            try persist()
            return try object(record)

        case "surface.attach":
            let conversationID = try required("conversationID", params)
            guard snapshot.conversations.contains(where: { $0.id == conversationID }) else {
                throw RegistryError.notFound("Unknown conversation: \(conversationID)")
            }
            let now = Date()
            let surfaceID = try required("surfaceID", params)
            let existing = snapshot.surfaces.first(where: { $0.id == surfaceID })
            let record = AgentSurfaceRecord(
                id: surfaceID,
                conversationID: conversationID,
                driverID: try required("driverID", params),
                kind: try required("kind", params),
                client: params["client"] as? String,
                attachedAt: existing?.attachedAt ?? now,
                lastSeenAt: now
            )
            upsert(record, in: &snapshot.surfaces)
            try persist()
            return try object(record)

        case "surface.detach":
            let surfaceID = try required("surfaceID", params)
            snapshot.surfaces.removeAll { $0.id == surfaceID }
            try persist()
            return ["detached": true, "surfaceID": surfaceID]

        case "delivery.submit":
            let conversationID = try required("conversationID", params)
            guard snapshot.conversations.contains(where: { $0.id == conversationID }) else {
                throw RegistryError.notFound("Unknown conversation: \(conversationID)")
            }
            let key = try required("idempotencyKey", params)
            if let existing = snapshot.deliveries.first(where: { $0.idempotencyKey == key }) {
                return try object(existing)
            }
            let now = Date()
            let record = AgentDeliveryRecord(
                id: UUID().uuidString.lowercased(),
                conversationID: conversationID,
                idempotencyKey: key,
                payload: try required("payload", params),
                state: .queued,
                createdAt: now,
                updatedAt: now,
                detail: nil
            )
            snapshot.deliveries.append(record)
            try persist()
            return try object(record)

        case "delivery.poll":
            let conversationID = try required("conversationID", params)
            let pending = snapshot.deliveries.filter {
                $0.conversationID == conversationID && [.queued, .accepted].contains($0.state)
            }
            return try object(pending)

        case "delivery.ack":
            let deliveryID = try required("deliveryID", params)
            guard let index = snapshot.deliveries.firstIndex(where: { $0.id == deliveryID }) else {
                throw RegistryError.notFound("Unknown delivery: \(deliveryID)")
            }
            guard let rawState = params["state"] as? String,
                  let state = AgentRuntimeDeliveryState(rawValue: rawState) else {
                throw RegistryError.invalidParams("state")
            }
            snapshot.deliveries[index].state = state
            snapshot.deliveries[index].detail = params["detail"] as? String
            snapshot.deliveries[index].updatedAt = Date()
            try persist()
            return try object(snapshot.deliveries[index])

        default:
            throw RegistryError.unsupportedMethod(method)
        }
    }

    private func required(_ key: String, _ params: [String: Any]) throws -> String {
        guard let value = params[key] as? String, !value.isEmpty else {
            throw RegistryError.invalidParams(key)
        }
        return value
    }

    private func upsert<T: Identifiable>(_ value: T, in values: inout [T]) where T.ID: Equatable {
        if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value }
        else { values.append(value) }
    }

    private func object<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder.runtimeEncoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func persist() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: AgentRuntimePaths.directory,
                                        withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700],
                                       ofItemAtPath: AgentRuntimePaths.directory.path)
        let data = try JSONEncoder.runtimeEncoder.encode(snapshot)
        try data.write(to: AgentRuntimePaths.registry, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600],
                                       ofItemAtPath: AgentRuntimePaths.registry.path)
    }
}

private extension JSONEncoder {
    static var runtimeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
