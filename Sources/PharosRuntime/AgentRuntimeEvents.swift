import Foundation

public struct AgentRuntimeEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UInt64 { sequence }
    public var sequence: UInt64
    public var kind: String
    public var timestamp: Date
    public var payload: String
}

/// Host-local ordered journal. Broker commands carry cursor reads across
/// machines; the journal itself remains beside the Host runtime it describes.
final class AgentRuntimeEventJournal: @unchecked Sendable {
    static let shared = AgentRuntimeEventJournal()

    private struct State: Codable {
        var nextSequence: UInt64
        var events: [AgentRuntimeEvent]
    }

    private let lock = NSLock()
    private let file = AgentRuntimePaths.directory.appendingPathComponent("agent-runtime-events.json")
    private var state: State

    private init() {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State(nextSequence: 1, events: [])
        }
    }

    func publish(kind: String, payload object: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("null".utf8)
        let payload = String(data: data, encoding: .utf8) ?? "null"
        lock.lock()
        let event = AgentRuntimeEvent(sequence: state.nextSequence, kind: kind,
                                      timestamp: Date(), payload: payload)
        state.nextSequence += 1
        state.events.append(event)
        if state.events.count > 2_048 { state.events.removeFirst(state.events.count - 2_048) }
        persistLocked()
        lock.unlock()
    }

    func cursorObject() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["cursor": state.nextSequence - 1]
    }

    func resumeObject(after cursor: UInt64) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let oldest = state.events.first?.sequence ?? state.nextSequence
        let resetRequired = cursor > 0 && cursor + 1 < oldest
        let selected = resetRequired ? state.events : state.events.filter { $0.sequence > cursor }
        let eventObjects: [[String: Any]] = selected.map {
            ["sequence": $0.sequence,
             "kind": $0.kind,
             "timestamp": $0.timestamp.timeIntervalSince1970,
             "payload": $0.payload]
        }
        return ["cursor": state.nextSequence - 1,
                "resetRequired": resetRequired,
                "events": eventObjects]
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: AgentRuntimePaths.directory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
