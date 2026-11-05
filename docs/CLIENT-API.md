# Pharos Client API Specification (`PharosClientKit`)

---
summary: Official specification for PharosClientKit, the single versioned boundary library connecting the SwiftUI desktop client to the Pharos backend runtime. Specifies the Canonical Message and Event Model, DTOs, PharosClientService protocol, streaming events, and explicit backend error handling per RFC-006.
---

- Authority & Design Reference: [RFC-006: Unified Client and Backend Integration](RFC-006-UNIFIED-CLIENT-AND-BACKEND-INTEGRATION.md)

## 1. Architectural Boundary & Isolation

In accordance with RFC-006 and Invariant 1:
- The macOS client app is a **pure presentation layer**. It does not perform process execution, socket dialing, mesh routing, or disk persistence directly.
- **`PharosClientKit`** is the single versioned library target through which the client communicates with the backend daemon.
- It depends strictly on `Foundation` and is completely decoupled from Apple GUI frameworks (`SwiftUI`, `AppKit`, `Cocoa`).
- Verified at compile-time and continuously guarded by `ArchitectureBoundaryTests`.

---

## 2. The Two Interaction Modes (RFC-006 §1)

1. **SESSION (1:1 Direct Agent Chat)**:
   - Human directly converses with an agent session over the mesh.
   - Client sends requests to the host node owning the session; host drives local vendor service (Codex daemon UDS, dsh web Host HTTP/WS, agy ACP stdio) and streams canonical events back over mesh.
   - Uniform path for local and remote hosts.
   - Uses the **Canonical Rich Message Model** (`CanonicalTurn`, `CanonicalStep`, `CanonicalBlock`, `CanonicalStreamingDelta`, `CanonicalApprovalRequest`).
2. **THREAD (Multi-Agent Group Conversation)**:
   - Multi-agent collaboration room over durable mesh mailbox (RFC-005 point-to-point delivery).
   - **Implicit Human Participant**: Human is an implicit, invisible participant of every thread by default (never in roster, can always send, receives all messages and replies, default reply target).
   - **Plain Chat Bubbles**: Uses the lightweight `ClientThreadMessage` DTO (sender ID, avatar seed, text, timestamp, delivery receipts). Agents emit only their final plain text reply upon turn completion.

---

## 3. Data Models & Schemas

### 3.1 JSONValue
A recursive, Sendable, Codable representation of arbitrary JSON data:
```swift
public enum JSONValue: Sendable, Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null
}
```

### 3.2 Canonical Session Models (1:1 Chat)
```swift
public struct CanonicalTurn: Sendable, Codable, Equatable, Identifiable {
    public let turnId: String
    public let sessionId: String
    public let turnNumber: Int
    public let status: TurnStatus // inProgress, completed, failed, cancelled, needsHuman
    public let createdAt: Date
    public let completedAt: Date?
    public let steps: [CanonicalStep]
    public let rawVendorPayload: [String: JSONValue]?
}

public struct CanonicalStep: Sendable, Codable, Equatable, Identifiable {
    public let stepId: String
    public let stepNumber: Int
    public let status: StepStatus // running, completed, failed
    public let blocks: [CanonicalBlock]
    public let rawVendorPayload: [String: JSONValue]?
}

public struct CanonicalBlock: Sendable, Codable, Equatable, Identifiable {
    public let blockId: String
    public let kind: CanonicalBlockKind
    public let rawVendorPayload: [String: JSONValue]?
}

public enum CanonicalBlockKind: Sendable, Codable, Equatable {
    case userText(String)
    case assistantText(String)
    case reasoning(CanonicalReasoningBlock)
    case toolCall(CanonicalToolCall)
    case toolResult(CanonicalToolResult)
    case terminalCommand(CanonicalTerminalCommand)
    case filePatch(CanonicalFilePatch)
    case attachment(CanonicalAttachment)
}
```

### 3.3 Streaming Deltas
High-frequency deltas are coalesced by the backend before emission to client streams to prevent UI redraw storms (RFC-006 §4):
```swift
public struct CanonicalStreamingDelta: Sendable, Codable, Equatable {
    public let sessionId: String
    public let turnId: String
    public let stepId: String?
    public let blockId: String?
    public let deltaType: DeltaType
}

public enum DeltaType: Sendable, Codable, Equatable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallDelta(callId: String, chunk: String)
    case terminalOutputDelta(String)
}
```

### 3.4 Approval Requests & Waterfalls
```swift
public struct CanonicalApprovalRequest: Sendable, Codable, Equatable, Identifiable {
    public let approvalId: String
    public let sessionId: String
    public let kind: ApprovalKind
    public let rawVendorPayload: [String: JSONValue]?
}

public enum ApprovalKind: Sendable, Codable, Equatable {
    case toolPermission(toolName: String, params: [String: JSONValue], explanation: String?)
    case structuredQuestionnaire(intent: String, questions: [CanonicalQuestionOption])
}
```

### 3.5 Plain Chat Bubble DTO (Threads)
```swift
public struct ClientThreadMessage: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let threadId: String
    public let senderId: String
    public let senderName: String
    public let senderAvatarSeed: String?
    public let text: String
    public let timestamp: Date
    public let receipt: DeliveryReceiptState // pending, delivered, consumed, unverifiedFallback
    public let attachments: [CanonicalAttachment]
}
```

### 3.6 Client Summaries
- `ClientSessionSummary`: Metadata for active 1:1 sessions (machine, agent, workspace, status, avatarSeed).
- `ClientThreadSummary`: Group thread roster and unread count.
- `ClientProjectSummary`: Workspace directory tracked across distributed nodes.
- `ClientMemberDetail`: Operational attributes (model, mode, status, tmux session).
- `ClientAvatarInfo`: Deterministic avatar seed and customization tokens.

---

## 4. Unified Service Protocol (`PharosClientService`)

```swift
public protocol PharosClientService: Sendable {
    func fetchSessions() async throws -> [ClientSessionSummary]
    func fetchThreads() async throws -> [ClientThreadSummary]
    func fetchProjects() async throws -> [ClientProjectSummary]
    func fetchSessionHistory(sessionId: String) async throws -> [CanonicalTurn]
    func fetchThreadMessages(threadId: String) async throws -> [ClientThreadMessage]
    func fetchMemberDetail(name: String) async throws -> ClientMemberDetail

    // 1:1 Session actions (live streaming, steering, approvals)
    func sendSessionMessage(sessionId: String, text: String) async throws -> CanonicalTurn
    func steerSession(sessionId: String, text: String) async throws
    func resolveSessionApproval(sessionId: String, approvalId: String, decision: ApprovalDecision) async throws

    // Thread Roster actions (reliable delivery, fanout, receipts)
    func sendThreadMessage(threadId: String, text: String) async throws -> ClientThreadMessage

    // Member administration
    func setMemberMode(name: String, mode: String) async throws
    func setMemberModel(name: String, model: String) async throws
    func setMemberAvatar(name: String, avatar: ClientAvatarInfo) async throws
    func stopMember(name: String) async throws
    func reviveMember(name: String) async throws

    /// Async stream of real-time client events.
    func events() -> AsyncStream<PharosClientEvent>
}
```

---

## 5. Explicit Error Handling & Daemon Failure Recovery

In accordance with `GOAL.md` (Added 16:18):
- When a vendor backend daemon (e.g. Codex daemon) is unreachable or restarts:
  - Pharos **NEVER silently drops messages**.
  - Surfaces explicit error `PharosClientError.backendUnreachable(backend: String, reason: String)` to the client UI.
  - Emits `.backendError` event into the event stream.
  - For Threads, emits an error delivery receipt to the sender.
  - After a daemon restart, Pharos re-establishes the connection and resumes the underlying session/thread before re-dispatching queued deliveries.

---

## 6. Deterministic Testing & Previews (`MockPharosClientService`)

`MockPharosClientService` provides an in-memory implementation of `PharosClientService`:
- Populated with fixture data for SwiftUI Previews and UI component testing.
- Supports programmatic event emission via `emitEvent(_:)`.
- Supports explicit backend failure simulation via `setBackendFailure(backend:reason:)` to test error presentation and recovery paths deterministically.
