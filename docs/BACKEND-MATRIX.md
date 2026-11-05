---
summary: Version-pinned capability matrix for Codex, Antigravity, and DeepSeek Harness across Session (1:1) and Thread (group chat) paths, mapping exact RPC methods, evidence, status, tasks, tests, and pitfalls.
---

# Pharos Backend Integration Matrix

- Authority & Design Reference: [RFC-006: Unified Client and Backend Integration](RFC-006-UNIFIED-CLIENT-AND-BACKEND-INTEGRATION.md)

This document is the authoritative specification and capability checklist for integrating agent CLIs into Pharos Milestone 3. Every backend capability is explicitly pinned to tested CLI versions, research evidence, implementation tasks, and automated tests.

---

## 1. Version Header & Research Provenance

All capability declarations and protocol mechanisms in this matrix are pinned to empirical reverse-engineering research conducted on `xiangs-mac-mini` (macOS 27.2 arm64) on **2026-11-05**:

| Backend / Component | Verified Version | Verified Executable / Bundle Location | Research Archive Path | Researched Date | Attachment Capability & Channel Type |
|---|---|---|---|---|---|
| **Codex CLI (`codex`)** | `codex-cli 0.166.0` | `/opt/homebrew/bin/codex`<br>`~/.codex/packages/app-server-daemon/releases/0.166.0-aarch64-apple-darwin` | `~/brainstorm/collections/research/codex/` | 2026-11-05 | Shared Daemon WebSocket-over-UDS (`~/.codex/app-server-control/app-server-control.sock`). Multi-client multiplexing via `thread/resume`. No tmux required. |
| **ChatGPT.app Codex Framework** | `156.0.8078.79`<br>(App `26.1029.61003`) | `/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework` | `~/brainstorm/collections/research/codex/2026-11-05_architecture.md` | 2026-11-05 | **NOT ATTACHABLE**. ChatGPT.app runs private stdio pipes (`codex app-server --listen stdio://`); exposes no local UDS or network listeners. `ipc.sock` is private desktop IPC. |
| **Antigravity CLI (`agy`)** | `1.5.1` | `/opt/homebrew/bin/agy` | `~/brainstorm/collections/research/antigravity-cli/` | 2026-11-05 | `agy acp` (ACP 1.5.0 stdio JSON-RPC long-running child held by headless Pharos daemon). Attached read-only via `presence/<id>.lock` flock + `transcript.jsonl` tailing. Tmux TUI fallback. |
| **DeepSeek Harness (`dsh`)** | `0.2.1-rc.5` | `/opt/homebrew/bin/dsh`<br>`dsh-plugin-pharos 0.2.0` | `~/brainstorm/collections/research/dsh-web/` | 2026-11-05 | **SESSION**: Pharos-owned `dsh web --no-open --port 0 --host 127.0.0.1` in tmux via HTTP/WS (`/api/session/*` + `session/follow`). In-memory token.<br>**THREAD**: In-process `dsh-plugin-pharos` delivery loop. |

---

## 2. Interaction Modes & Version-Drift Safety Rules

### 2.1 The Two Interaction Modes (RFC-006 §1 & GOAL.md 15:02)
Pharos strictly separates client-agent interactions into two distinct paths:
1. **SESSION (1:1 Direct Chat over Mesh)**:
   - In the universal session view, the human talks directly to one agent session over the mesh.
   - The client dispatches requests to the Pharos node on the host that owns the session. That host node drives the vendor service locally (Codex daemon UDS, dsh web Host HTTP/WS, agy ACP stdio) and streams canonical events back over the mesh to the client.
   - Local and remote hosts share the exact same execution path.
   - Operates under the **Canonical Rich Message & Event Model** (`docs/MESSAGE-MODEL.md`: turns, steps, thinking, typing deltas, tool execution cards, approval waterfalls).
2. **THREAD (Multi-Agent Group Conversation)**:
   - The human posts in a group conversation and addresses specific agents over the durable mesh mailbox (RFC-005 point-to-point delivery).
   - **Implicit Human Participant**: The human is an **implicit, invisible participant of every thread** by default. They are never listed in the roster, but can always post, receive all messages and replies, and serve as the default reply target. No join step is needed.
   - **Plain Chat Bubbles**: Threads do NOT use the rich hierarchical block model. Messages are simple chat bubbles (`ClientThreadMessage`: sender ID, avatar seed, text, timestamp, delivery receipts). An agent's thread reply is strictly its final text, with zero intermediate thinking, tool, or step events.

### 2.2 Version-Drift Safety & Degradation Rules

1. **Connect-Time Handshake**: Every adapter MUST verify the underlying CLI version during initialization before issuing operational commands:
   - `CodexAdapter`: Calls `codex app-server daemon version` (and JSON-RPC `initialize`). Verifies `appServerVersion >= 0.141.0`.
   - `AgyAdapter`: Inspects `agy --version` and ACP `initialize` response capabilities.
   - `DshAdapter`: Inspects `dsh --version` (or bundle ASAR `package.json`).
2. **Safe Degradation Protocol**:
   - If a backend version does not match the pinned version or falls below required capability thresholds:
     - The adapter emits a structured log warning: `[BackendMatrix] WARNING: <backend> version mismatch (detected <v>, pinned <v_pinned>). Degrading to safe fallback.`
     - Features flagged as requiring newer protocol extensions degrade to conservative fallbacks (e.g. streaming deltas degrade to turn completion polling; ACP model switching degrades to graceful restart).
3. **Immutability of the Matrix**: This matrix is the ground truth. Automated unit and integration tests validate adapter behavior against the declared row IDs below.

---

## 3. Comprehensive Feature Checklist Matrix

Status definitions:
- `supported`: Fully proven by research archive and verified runnable on the pinned version.
- `partial`: Supported with documented workaround or operational constraint.
- `unsupported`: Explicitly impossible or prohibited due to CLI defects/architecture.
- `untested`: Structurally designed and supported by protocol schema, awaiting M3 test execution.
- (All research archives finalized: Codex 0.166.0, Antigravity 1.5.1, DeepSeek Harness 0.2.1-rc.5).

### 3.1 Codex CLI (`codex-cli 0.166.0`)

| Row ID | Backend | Path | Feature | Mechanism | Status | Researched Version | Evidence | Pharos Task ID | Test That Will Prove It |
|---|---|---|---|---|---|---|---|---|---|
| `CX-SES-01` | `codex` | `Session` | `discover/list` | `thread/loaded/list` (active daemon threads) + SQLite query on `state_5.sqlite` (`preview <> ''`) | `supported` | `0.166.0` | `codex/2026-11-05_storage.md §4` | Goal 2.1, Goal 4 | `CodexDaemonClientTests.testDiscoverPersistedSessionsQuery` |
| `CX-SES-02` | `codex` | `Session` | `live-status` | Subscribe `thread/status/changed`; inspect `thread/read` activeFlags (`waitingOnApproval`, `isBusy`) | `supported` | `0.166.0` | `codex/2026-11-05_sockets.md §3` | Goal 2.1, Goal 4 | `CodexDaemonWatcherTests.testWatcherPushesEventsAndUpdatesWatchFile` |
| `CX-SES-03` | `codex` | `Session` | `create` | `thread/start` with `cwd`, `approvalPolicy`, `sandbox` | `supported` | `0.166.0` | `codex/2026-11-05_protocol.md §4` | Goal 2.1, Goal 4 | `TriBackendAdapterTests.testCodexBackendAdapterLifecycleAndStreaming` |
| `CX-SES-04` | `codex` | `Session` | `resume` | `thread/resume` after first prompt is persisted (requires rollout flush) | `supported` | `0.166.0` | `codex/2026-11-05_sockets.md §7.6` | Goal 2.1, Goal 4 | `CodexDaemonClientTests.testThreadStartAndResume` |
| `CX-SES-05` | `codex` | `Session` | `send` | `turn/start` with `input:[{type:"text", text:...}]` | `supported` | `0.166.0` | `codex/2026-11-05_protocol.md §5` | Goal 2.1, Goal 4 | `TriBackendAdapterTests.testCodexBackendAdapterLifecycleAndStreaming` |
| `CX-SES-06` | `codex` | `Session` | `steer` | `turn/steer` with `expectedTurnId` or `turn/start` mid-turn | `supported` | `0.166.0` | `codex/2026-11-05_sockets.md §4.2` | Goal 2.1, Goal 4 | `SessionStreamingAndSteeringTests.testSessionConversationViewModelMidTurnSteering` |
| `CX-SES-07` | `codex` | `Session` | `streaming` | Real-time `item/agentMessage/delta` and `item/started|completed` WebSocket notifications | `supported` | `0.166.0` | `codex/2026-11-05_sockets.md §5` | Goal 2.1, Goal 4 | `SessionStreamingAndSteeringTests.testSessionConversationViewModelTurnStreamingAndCompletion` |
| `CX-SES-08` | `codex` | `Session` | `readback` | Final text from `turn/completed` + completed agentMessage items | `supported` | `0.166.0` | `codex/2026-11-05_sockets.md §5.2` | Goal 2.1, Goal 4 | `CodexDaemonClientTests.testTurnStartAndReadback` |
| `CX-SES-09` | `codex` | `Session` | `interrupt` | `turn/interrupt` RPC | `supported` | `0.166.0` | `codex/2026-11-05_protocol-methods.json` | Goal 2.1, Goal 4 | `SessionStreamingAndSteeringTests.testSessionConversationViewModelInterruptSession` |
| `CX-SES-10` | `codex` | `Session` | `approvals` | Server request `item/commandExecution/requestApproval` -> JSON-RPC decision response (`ApprovalBroker`) | `supported` | `0.166.0` | `codex/2026-11-05_approvals.md §3` | Goal 2.1, Goal 4 | `SessionStreamingAndSteeringTests.testSessionConversationViewModelApprovalWorkflow` |
| `CX-SES-11` | `codex` | `Session` | `model-select` | Graceful restart fallback (`/quit` -> wait -> `codex resume -m <model>`) | `partial` | `0.166.0` | `codex/PITFALLS.md P9` | Goal 2.1, Goal 7 | `ConversationDetailsTests.testModelMutationCommandGeneration` |
| `CX-SES-12` | `codex` | `Session` | `permission-mode` | Set `approvalPolicy: "never"` + `sandbox: "danger-full-access"` on thread launch/resume | `supported` | `0.166.0` | `codex/PITFALLS.md P12` | Goal 2.1, Goal 7 | `ConversationDetailsTests.testModeMutationCommandGenerationAndExecution` |
| `CX-SES-13` | `codex` | `Session` | `receipts` | Request ID correlation + `turn/started` notification confirmation | `supported` | `0.166.0` | `codex/2026-11-05_sockets.md §3` | Goal 2.1, Goal 4 | `TriBackendAdapterTests.testCodexBackendAdapterLifecycleAndStreaming` |
| `CX-SES-14` | `codex` | `Session` | `history-backfill` | `thread/turns/list` + `thread/items/list` reconciling missing turns after reconnect | `untested` | `0.166.0` | `codex/2026-11-05_storage.md §4` | Goal 2.1, Goal 4 | `CodexDaemonClientTests.testDiscoverPersistedSessionsQuery` |
| `CX-SES-15` | `codex` | `Session` | `cross-machine` | Client dispatches to session's host Pharos node over mesh; host node drives local Codex daemon via UDS and streams canonical events back (uniform path per RFC-006 §1) | `untested` | `0.166.0` | `codex/2026-11-05_pharos.md §3` | Goal 1, Goal 4 | `BackendIntegrationTests.testCodexRealDaemonIntegration` |
| `CX-SES-16` | `codex` | `Session` | `project-cwd` | Explicit `cwd` parameter on `thread/start` + project directory matching | `supported` | `0.166.0` | `codex/2026-11-05_protocol.md §4` | Goal 2.1, Goal 4 | `TriBackendAdapterTests.testCodexBackendAdapterLifecycleAndStreaming` |
| `CX-SES-17` | `codex` | `Session` | `avatars-identity` | Deterministic avatar seed computed from memberID + threadId; rendered in session row | `supported` | `0.166.0` | `GOAL.md Added 11:47` | Goal 6 | `ThreadChatAndReceiptTests.testThreadConversationViewModelMessageDelivery` |
| `CX-SES-18` | `codex` | `Session` | `daemon-failure-recovery` | Surface explicit error to client on daemon unreachable / restart (never drop message); resume thread before re-delivery | `supported` | `0.166.0` | `GOAL.md Added 16:18` | Goal 1, Goal 2.1, Goal 4 | `TriBackendAdapterTests.testCodexBackendAdapterDaemonUnreachableError` |
| `CX-THD-01` | `codex` | `Thread` | `discover/list` | Pharos Mesh room member roster. Human is an implicit, invisible participant of every thread by default (RFC-006 §1; never in roster, always receives, default reply target) | `supported` | `0.166.0` | `Sources/PharosRuntime/MeshBroker.swift` | Goal 2.1, Goal 5 | `ThreadChatAndReceiptTests.testThreadRosterBarExcludesHuman` |
| `CX-THD-02` | `codex` | `Thread` | `live-status` | Member presence broadcast via broker mesh + daemon active status | `supported` | `0.166.0` | `codex/2026-11-05_sockets.md §3` | Goal 2.1, Goal 5 | `ThreadChatAndReceiptTests.testThreadRosterBarExcludesHuman` |
| `CX-THD-03` | `codex` | `Thread` | `create` | Pharos `thread create --members <list>` creates durable mesh room (human auto-participates implicitly without joining) | `supported` | `0.166.0` | `Sources/PharosRuntime/CLI.swift` | Goal 2.1, Goal 5 | `ThreadChatAndReceiptTests.testThreadRosterBarExcludesHuman` |
| `CX-THD-04` | `codex` | `Thread` | `resume` | Member rejoins mesh room on broker startup using stable member ID | `supported` | `0.166.0` | `Sources/PharosRuntime/MeshBroker.swift` | Goal 2.1, Goal 5 | `MemberModelTests.testSwitchModelLocal` |
| `CX-THD-05` | `codex` | `Thread` | `send` | Durable mailbox dispatches message via daemon `turn/start` into member's own thread | `supported` | `0.166.0` | `codex/2026-11-05_pharos.md §3` | Goal 2.1, Goal 5 | `ThreadChatAndReceiptTests.testThreadConversationViewModelMessageDelivery` |
| `CX-THD-06` | `codex` | `Thread` | `steer` | N/A: Thread delivery queues next turn; mid-turn steering is not used in Thread roster | `unsupported` | `0.166.0` | `GOAL.md Added 13:36` | Goal 5 | `ThreadChatAndReceiptTests.testThreadConversationViewModelMessageDelivery` |
| `CX-THD-07` | `codex` | `Thread` | `streaming` | N/A: Thread roster delivers completed messages upon turn finish; token streaming not required | `unsupported` | `0.166.0` | `GOAL.md Added 13:36` | Goal 5 | `ThreadChatAndReceiptTests.testThreadConversationViewModelAgentPlainReply` |
| `CX-THD-08` | `codex` | `Thread` | `readback` | Extracts final assistant message upon `turn/completed`; posts back to mesh thread | `supported` | `0.166.0` | `codex/2026-11-05_sockets.md §5` | Goal 2.1, Goal 5 | `ThreadChatAndReceiptTests.testThreadConversationViewModelAgentPlainReply` |
| `CX-THD-09` | `codex` | `Thread` | `interrupt` | `turn/interrupt` RPC sent to daemon thread associated with member | `supported` | `0.166.0` | `codex/2026-11-05_protocol-methods.json` | Goal 2.1, Goal 5 | `CodexDaemonClientTests.testInterruptActiveTurn` |
| `CX-THD-10` | `codex` | `Thread` | `approvals` | `needs_human` event broadcast to thread timeline; answered by operator | `supported` | `0.166.0` | `codex/2026-11-05_approvals.md §4` | Goal 2.1, Goal 5 | `SessionStreamingAndSteeringTests.testSessionConversationViewModelApprovalWorkflow` |
| `CX-THD-11` | `codex` | `Thread` | `model-select` | Member config updated; next turn runs with specified model (or restart fallback) | `partial` | `0.166.0` | `codex/PITFALLS.md P9` | Goal 2.1, Goal 5 | `MemberModelTests.testSwitchModelLocal` |
| `CX-THD-12` | `codex` | `Thread` | `permission-mode` | Member mode tracked in LightRelay; applied to underlying member session | `supported` | `0.166.0` | `Sources/PharosRuntime/LightCommands.swift` | Goal 2.1, Goal 5 | `TriBackendAdapterTests.testCodexBackendAdapterLifecycleAndStreaming` |
| `CX-THD-13` | `codex` | `Thread` | `receipts` | 4-stage delivery receipt: `pending` -> `delivered` -> `consumed` -> `unverifiedFallback` | `supported` | `0.166.0` | `GOAL.md Added 13:36` | Goal 2.1, Goal 5 | `ThreadChatAndReceiptTests.testThreadConversationViewModelReceiptProgression` |
| `CX-THD-14` | `codex` | `Thread` | `history-backfill` | Mesh room durable mailbox log backfill on join/reconnect | `untested` | `0.166.0` | `Sources/PharosRuntime/MeshBroker.swift` | Goal 2.1, Goal 5 | `CodexDaemonClientTests.testDiscoverPersistedSessionsQuery` |
| `CX-THD-15` | `codex` | `Thread` | `cross-machine` | Mesh packet sent to remote host Pharos node; remote node executes local daemon `turn/start` | `untested` | `0.166.0` | `GOAL.md Added 13:36` | Goal 5 | `BackendIntegrationTests.testCodexRealDaemonIntegration` |
| `CX-THD-16` | `codex` | `Thread` | `project-cwd` | Thread bound to registered project workspace path across all roster members | `supported` | `0.166.0` | `Sources/PharosRuntime/ProjectStore.swift` | Goal 5 | `TriBackendAdapterTests.testCodexBackendAdapterLifecycleAndStreaming` |
| `CX-THD-17` | `codex` | `Thread` | `avatars-identity` | Sender avatar seed + member name rendered in thread message bubble | `supported` | `0.166.0` | `GOAL.md Added 11:47` | Goal 5, Goal 6 | `ThreadChatAndReceiptTests.testThreadConversationViewModelMessageDelivery` |
| `CX-THD-18` | `codex` | `Thread` | `daemon-failure-recovery` | Emit explicit error receipt/notification to sender on daemon unreachable / restart (never drop message); resume thread before queued delivery | `supported` | `0.166.0` | `GOAL.md Added 16:18` | Goal 2.1, Goal 5 | `TriBackendAdapterTests.testCodexBackendAdapterDaemonUnreachableError` |

---

### 3.2 Antigravity CLI (`agy 1.5.1`)

| Row ID | Backend | Path | Feature | Mechanism | Status | Researched Version | Evidence | Pharos Task ID | Test That Will Prove It |
|---|---|---|---|---|---|---|---|---|---|
| `AG-SES-01` | `agy` | `Session` | `discover/list` | SQLite `conversation_summaries.db` + non-blocking `flock(LOCK_EX | LOCK_NB)` on `presence/<id>.lock` | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_integration-matrix.md §2` | Goal 2.2, Goal 4 | `SessionInventoryTests.testDiscoverSessions` |
| `AG-SES-02` | `agy` | `Session` | `live-status` | ACP connection status + TUI footer check (`? for shortcuts` vs `esc to cancel`) | `supported` | `1.5.1` | `docs/PITFALLS.md` | Goal 2.2, Goal 4 | `AgyPaneTests.testLiveStatusClassification` |
| `AG-SES-03` | `agy` | `Session` | `create` | ACP `session/new` (or `session/load`) via long-running `agy acp` process | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_agy-channels.md §2` | Goal 2.2, Goal 4 | `TriBackendAdapterTests.testAgyBackendAdapterLifecycleAndApprovals` |
| `AG-SES-04` | `agy` | `Session` | `resume` | ACP `session/resume` with conversation ID (probed via presence flock) | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_integration-matrix.md §2` | Goal 2.2, Goal 4 | `TriBackendAdapterTests.testAgyBackendAdapterLifecycleAndApprovals` |
| `AG-SES-05` | `agy` | `Session` | `send` | ACP `session/prompt` with text string | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_agy-channels.md §2` | Goal 2.2, Goal 4 | `TriBackendAdapterTests.testAgyBackendAdapterLifecycleAndApprovals` |
| `AG-SES-06` | `agy` | `Session` | `steer` | ACP `session/prompt` submitted while turn is running (mid-turn append/steering) | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_integration-matrix.md §1` | Goal 2.2, Goal 4 | `SessionStreamingAndSteeringTests.testSessionConversationViewModelMidTurnSteering` |
| `AG-SES-07` | `agy` | `Session` | `streaming` | Real-time `session/update` chunks emitting token and tool delta objects | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_agy-channels.md §2` | Goal 2.2, Goal 4 | `CanonicalMessageMappingTests.testAgyMessageTranslatorStreamingAndPermissions` |
| `AG-SES-08` | `agy` | `Session` | `readback` | ACP `session/prompt` stopReason result + completed planner response in `transcript.jsonl` | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_agy-transcript-and-state.md` | Goal 2.2, Goal 4 | `CanonicalMessageMappingTests.testAgyMessageTranslatorStreamingAndPermissions` |
| `AG-SES-09` | `agy` | `Session` | `interrupt` | Send SIGINT or cancel notification to ACP session | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_agy-channels.md §2` | Goal 2.2, Goal 4 | `SessionStreamingAndSteeringTests.testSessionConversationViewModelInterruptSession` |
| `AG-SES-10` | `agy` | `Session` | `approvals` | ACP `session/request_permission` notification forwarded to UI; decision returned | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_agy-sessions-permissions.md` | Goal 2.2, Goal 4 | `TriBackendAdapterTests.testAgyBackendAdapterLifecycleAndApprovals` |
| `AG-SES-11` | `agy` | `Session` | `model-select` | Dynamic in-session switch via ACP `session/set_config_option` (from `configOptions`) | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_integration-matrix.md §1` | Goal 2.2, Goal 7 | `ConversationDetailsTests.testModelMutationCommandGeneration` |
| `AG-SES-12` | `agy` | `Session` | `permission-mode` | ACP initialize configuration / `--dangerously-skip-permissions` flag on startup | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_agy-sessions-permissions.md` | Goal 2.2, Goal 7 | `ConversationDetailsTests.testModeMutationCommandGenerationAndExecution` |
| `AG-SES-13` | `agy` | `Session` | `receipts` | ACP `session/prompt` response acknowledgment + stopReason confirmation | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_integration-matrix.md §1` | Goal 2.2, Goal 4 | `TriBackendAdapterTests.testAgyBackendAdapterLifecycleAndApprovals` |
| `AG-SES-14` | `agy` | `Session` | `history-backfill` | Tail and parse `transcript.jsonl` from session directory upon reconnect | `untested` | `1.5.1` | `antigravity-cli/2026-11-05_agy-transcript-and-state.md` | Goal 2.2, Goal 4 | `AgyTranscriptTests.testTranscriptParseBackfill` |
| `AG-SES-15` | `agy` | `Session` | `cross-machine` | Client dispatches to session's host Pharos node over mesh; host node drives local agy ACP stdio and streams canonical events back (uniform path per RFC-006 §1) | `untested` | `1.5.1` | `GOAL.md Added 13:36` | Goal 1, Goal 4 | `BackendIntegrationTests.testAgyRealAcpProcessIntegration` |
| `AG-SES-16` | `agy` | `Session` | `project-cwd` | Spawn `agy acp` with `currentDirectory` set to registered project path | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_agy-channels.md §2` | Goal 2.2, Goal 4 | `TriBackendAdapterTests.testAgyBackendAdapterLifecycleAndApprovals` |
| `AG-SES-17` | `agy` | `Session` | `avatars-identity` | Deterministic avatar seed computed from memberID + conversationId | `supported` | `1.5.1` | `GOAL.md Added 11:47` | Goal 6 | `ThreadChatAndReceiptTests.testThreadConversationViewModelMessageDelivery` |
| `AG-THD-01` | `agy` | `Thread` | `discover/list` | Pharos Mesh room member roster. Human is an implicit, invisible participant of every thread by default (RFC-006 §1; never in roster, always receives, default reply target) | `supported` | `1.5.1` | `Sources/PharosRuntime/MeshBroker.swift` | Goal 2.2, Goal 5 | `ThreadChatAndReceiptTests.testThreadRosterBarExcludesHuman` |
| `AG-THD-02` | `agy` | `Thread` | `live-status` | Member presence broadcast via broker mesh + presence flock liveness | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_integration-matrix.md §2` | Goal 2.2, Goal 5 | `ThreadChatAndReceiptTests.testThreadRosterBarExcludesHuman` |
| `AG-THD-03` | `agy` | `Thread` | `create` | Pharos `thread create --members <list>` creates durable mesh room (human auto-participates implicitly without joining) | `supported` | `1.5.1` | `Sources/PharosRuntime/CLI.swift` | Goal 2.2, Goal 5 | `ThreadChatAndReceiptTests.testThreadRosterBarExcludesHuman` |
| `AG-THD-04` | `agy` | `Thread` | `resume` | Member rejoins mesh room on broker startup using conversation ID | `supported` | `1.5.1` | `Sources/PharosRuntime/MeshBroker.swift` | Goal 2.2, Goal 5 | `MemberModelTests.testSwitchModelLocal` |
| `AG-THD-05` | `agy` | `Thread` | `send` | Durable mailbox dispatches message via ACP `session/prompt` (tmux fallback) | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_integration-matrix.md §3` | Goal 2.2, Goal 5 | `ThreadChatAndReceiptTests.testThreadConversationViewModelMessageDelivery` |
| `AG-THD-06` | `agy` | `Thread` | `steer` | N/A: Thread delivery queues next prompt; mid-turn steering is not used in Thread roster | `unsupported` | `1.5.1` | `GOAL.md Added 13:36` | Goal 5 | `ThreadChatAndReceiptTests.testThreadConversationViewModelMessageDelivery` |
| `AG-THD-07` | `agy` | `Thread` | `streaming` | N/A: Thread roster delivers completed messages upon turn finish; token streaming not required | `unsupported` | `1.5.1` | `GOAL.md Added 13:36` | Goal 5 | `ThreadChatAndReceiptTests.testThreadConversationViewModelAgentPlainReply` |
| `AG-THD-08` | `agy` | `Thread` | `readback` | Extracts final assistant response upon ACP stopReason / transcript write; posts to thread | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_integration-matrix.md §3` | Goal 2.2, Goal 5 | `ThreadChatAndReceiptTests.testThreadConversationViewModelAgentPlainReply` |
| `AG-THD-09` | `agy` | `Thread` | `interrupt` | Cancel signal dispatched to member's ACP session | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_agy-channels.md §2` | Goal 2.2, Goal 5 | `SessionStreamingAndSteeringTests.testSessionConversationViewModelInterruptSession` |
| `AG-THD-10` | `agy` | `Thread` | `approvals` | `needs_human` event forwarded from ACP permission request into thread timeline | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_integration-matrix.md §3` | Goal 2.2, Goal 5 | `SessionStreamingAndSteeringTests.testSessionConversationViewModelApprovalWorkflow` |
| `AG-THD-11` | `agy` | `Thread` | `model-select` | Dynamic model switch applied via ACP `session/set_config_option` | `supported` | `1.5.1` | `antigravity-cli/2026-11-05_integration-matrix.md §1` | Goal 2.2, Goal 5 | `TriBackendAdapterTests.testCapabilityRegistryRetrievalAndDegradation` |
| `AG-THD-12` | `agy` | `Thread` | `permission-mode` | Member mode tracked in LightRelay; applied to underlying member session | `supported` | `1.5.1` | `Sources/PharosRuntime/LightCommands.swift` | Goal 2.2, Goal 5 | `TriBackendAdapterTests.testAgyBackendAdapterLifecycleAndApprovals` |
| `AG-THD-13` | `agy` | `Thread` | `receipts` | 4-stage delivery receipt: `pending` -> `delivered` -> `consumed` -> `unverifiedFallback` | `supported` | `1.5.1` | `GOAL.md Added 13:36` | Goal 2.2, Goal 5 | `ThreadChatAndReceiptTests.testThreadConversationViewModelReceiptProgression` |
| `AG-THD-14` | `agy` | `Thread` | `history-backfill` | Mesh room durable mailbox log backfill on join/reconnect | `untested` | `1.5.1` | `Sources/PharosRuntime/MeshBroker.swift` | Goal 2.2, Goal 5 | `AgyTranscriptTests.testTranscriptParseBackfill` |
| `AG-THD-15` | `agy` | `Thread` | `cross-machine` | Mesh packet sent to remote host Pharos node; remote node executes ACP `session/prompt` | `untested` | `1.5.1` | `GOAL.md Added 13:36` | Goal 5 | `BackendIntegrationTests.testAgyRealAcpProcessIntegration` |
| `AG-THD-16` | `agy` | `Thread` | `project-cwd` | Thread bound to registered project workspace path across all roster members | `supported` | `1.5.1` | `Sources/PharosRuntime/ProjectStore.swift` | Goal 5 | `TriBackendAdapterTests.testAgyBackendAdapterLifecycleAndApprovals` |
| `AG-THD-17` | `agy` | `Thread` | `avatars-identity` | Sender avatar seed + member name rendered in thread message bubble | `supported` | `1.5.1` | `GOAL.md Added 11:47` | Goal 5, Goal 6 | `ThreadChatAndReceiptTests.testThreadConversationViewModelMessageDelivery` |

---

### 3.3 DeepSeek Harness (`dsh 0.2.1-rc.5`)

| Row ID | Backend | Path | Feature | Mechanism | Status | Researched Version | Evidence | Pharos Task ID | Test That Will Prove It |
|---|---|---|---|---|---|---|---|---|---|
| `DS-SES-01` | `dsh` | `Session` | `discover/list` | Uncompressed projection cache `*.json` or web `POST /api/session/list` | `untested` | `0.2.1-rc.5` | `dsh-web/2026-11-05_pharos-mapping.md §1.1, §2` | Goal 2.3, Goal 4 | `TriBackendAdapterTests.testDshBackendAdapterStartupParsingAndLifecycle` |
| `DS-SES-02` | `dsh` | `Session` | `live-status` | `session/list` row `.running`, `turn/start`/`end` in `session/follow`, or `$events` `api-session/status` | `supported` | `0.2.1-rc.5` | `dsh-web/2026-11-05_pharos-mapping.md §1.1, §2` | Goal 2.3, Goal 4 | `TriBackendAdapterTests.testDshBackendAdapterStartupParsingAndLifecycle` |
| `DS-SES-03` | `dsh` | `Session` | `create` | Spawns `dsh --profile web --no-open --port 0 --host 127.0.0.1` in tmux; parses stdout URL token; `/connect` cookie; `POST /api/session/create` | `supported` | `0.2.1-rc.5` | `dsh-web/2026-11-05_lifecycle-auth.md §1-2` | Goal 2.3, Goal 4 | `TriBackendAdapterTests.testDshBackendAdapterStartupParsingAndLifecycle` |
| `DS-SES-04` | `dsh` | `Session` | `resume` | Re-attaches to persistent web Host in tmux via `session/follow` or `session/prompt` (single flock per session) | `supported` | `0.2.1-rc.5` | `dsh-web/2026-11-05_pharos-mapping.md §1.1` | Goal 2.3, Goal 4 | `TriBackendAdapterTests.testDshBackendAdapterStartupParsingAndLifecycle` |
| `DS-SES-05` | `dsh` | `Session` | `send` | `POST /api/session/prompt` (`mode: "queue"`) carrying authority-bound session cookie | `supported` | `0.2.1-rc.5` | `dsh-web/2026-11-05_rpc-methods.md §3` | Goal 2.3, Goal 4 | `TriBackendAdapterTests.testDshBackendAdapterStartupParsingAndLifecycle` |
| `DS-SES-06` | `dsh` | `Session` | `steer` | `POST /api/session/prompt` (`mode: "steer"`) injects mid-turn steering message consumed at next turn step | `supported` | `0.2.1-rc.5` | `dsh-web/2026-11-05_rpc-methods.md §3` | Goal 2.3, Goal 4 | `SessionStreamingAndSteeringTests.testSessionConversationViewModelMidTurnSteering` |
| `DS-SES-07` | `dsh` | `Session` | `streaming` | Real-time WebSocket mux stream on `/api/remote.mux` (`session/follow` with `assistantStream: true`) | `supported` | `0.2.1-rc.5` | `dsh-web/2026-11-05_mux-protocol.md §3` | Goal 2.3, Goal 4 | `CanonicalMessageMappingTests.testDshMessageTranslatorMuxAndApprovals` |
| `DS-SES-08` | `dsh` | `Session` | `readback` | Durable turn reply read back from `session/follow` event (`assistant/message`) or `turn/end` | `supported` | `0.2.1-rc.5` | `dsh-web/2026-11-05_pharos-mapping.md §1.2` | Goal 2.3, Goal 4 | `CanonicalMessageMappingTests.testDshMessageTranslatorMuxAndApprovals` |
| `DS-SES-09` | `dsh` | `Session` | `interrupt` | `POST /api/session/cancel` with `{sessionId}` (`session/control` is a read-only projection stream) | `supported` | `0.2.1-rc.5` | `dsh-web/2026-11-05_pharos-mapping.md §1.7, §2` | Goal 2.3, Goal 4 | `SessionStreamingAndSteeringTests.testSessionConversationViewModelInterruptSession` |
| `DS-SES-10` | `dsh` | `Session` | `approvals` | `$events` mux stream receives `approval/request` waterfall; answered via `POST /api/$events/result` | `supported` | `0.2.1-rc.5` | `dsh-web/2026-11-05_pharos-mapping.md §1.4, §2` | Goal 2.3, Goal 4 | `CanonicalMessageMappingTests.testDshMessageTranslatorMuxAndApprovals` |
| `DS-SES-11` | `dsh` | `Session` | `model-select` | `POST /api/session/selectModel` with `{sessionId, provider, model}`; durable audit in `model/selection` | `supported` | `0.2.1-rc.5` | `dsh-web/2026-11-05_pharos-mapping.md §1.6, §2` | Goal 2.3, Goal 7 | `ConversationDetailsTests.testModelMutationCommandGeneration` |
| `DS-SES-12` | `dsh` | `Session` | `permission-mode` | `POST /api/commands/execute` with `line: "/permission <preset>"` or profile config patch | `supported` | `0.2.1-rc.5` | `dsh-web/2026-11-05_pharos-mapping.md §1.6` | Goal 2.3, Goal 7 | `ConversationDetailsTests.testModeMutationCommandGenerationAndExecution` |
| `DS-SES-13` | `dsh` | `Session` | `receipts` | Admission receipt via `session/prompt` response `{accepted: true, requestId}`; durable via `user/message.source.rpcId` | `supported` | `0.2.1-rc.5` | `dsh-web/2026-11-05_pharos-mapping.md §1.2, §1.7` | Goal 2.3, Goal 4 | `TriBackendAdapterTests.testDshBackendAdapterStartupParsingAndLifecycle` |
| `DS-SES-14` | `dsh` | `Session` | `history-backfill` | `session/follow` snapshot (last 50 messages) + gap backfill via `POST /api/session/page` + projection cache `*.json` | `untested` | `0.2.1-rc.5` | `dsh-web/2026-11-05_pharos-mapping.md §1.2, §3.4` | Goal 2.3, Goal 4 | `TriBackendAdapterTests.testDshBackendAdapterStartupParsingAndLifecycle` |
| `DS-SES-15` | `dsh` | `Session` | `cross-machine` | Client dispatches to session's host Pharos node over mesh; host node drives local dsh web Host via HTTP/WS and streams canonical events back (uniform path per RFC-006 §1) | `untested` | `0.2.1-rc.5` | `GOAL.md Added 13:36` | Goal 1, Goal 4 | `BackendIntegrationTests.testDshRealWebHostIntegration` |
| `DS-SES-16` | `dsh` | `Session` | `project-cwd` | Single-writer `workspace.json` registered via `workspace/create` + `workspace/follow` baseline frame | `supported` | `0.2.1-rc.5` | `dsh-web/2026-11-05_pharos-mapping.md §2` | Goal 2.3, Goal 4 | `TriBackendAdapterTests.testDshBackendAdapterStartupParsingAndLifecycle` |
| `DS-SES-17` | `dsh` | `Session` | `avatars-identity` | Deterministic avatar seed computed from memberID + dsh `agent.session.id` | `supported` | `0.2.1-rc.5` | `GOAL.md Added 11:47` | Goal 6 | `ThreadChatAndReceiptTests.testThreadConversationViewModelMessageDelivery` |
| `DS-THD-01` | `dsh` | `Thread` | `discover/list` | Pharos Mesh room member roster. Human is an implicit, invisible participant of every thread by default (RFC-006 §1; never in roster, always receives, default reply target) | `supported` | `0.2.1-rc.5` | `Sources/PharosRuntime/MeshBroker.swift` | Goal 2.3, Goal 5 | `ThreadChatAndReceiptTests.testThreadRosterBarExcludesHuman` |
| `DS-THD-02` | `dsh` | `Thread` | `live-status` | Member presence broadcast via broker mesh + Runtime driver registration | `supported` | `0.2.1-rc.5` | `antigravity-cli/2026-11-05_dsh-plugin-adapter.md §2` | Goal 2.3, Goal 5 | `ThreadChatAndReceiptTests.testThreadRosterBarExcludesHuman` |
| `DS-THD-03` | `dsh` | `Thread` | `create` | Pharos `thread create --members <list>` creates durable mesh room (human auto-participates implicitly without joining) | `supported` | `0.2.1-rc.5` | `Sources/PharosRuntime/CLI.swift` | Goal 2.3, Goal 5 | `ThreadChatAndReceiptTests.testThreadRosterBarExcludesHuman` |
| `DS-THD-04` | `dsh` | `Thread` | `resume` | `dsh-plugin-pharos` reconnects to Runtime socket and re-registers session binding | `supported` | `0.2.1-rc.5` | `antigravity-cli/2026-11-05_dsh-plugin-adapter.md §2` | Goal 2.3, Goal 5 | `AgentAdapterTests.testHostRuntimeRoutesGenericAdapterMethodsOverPrivateSocket` |
| `DS-THD-05` | `dsh` | `Thread` | `send` | Runtime `delivery.submit-member` -> plugin `delivery.poll` -> `agent.followup()` | `supported` | `0.2.1-rc.5` | `antigravity-cli/2026-11-05_dsh-plugin-adapter.md §3` | Goal 2.3, Goal 5 | `ThreadChatAndReceiptTests.testThreadConversationViewModelMessageDelivery` |
| `DS-THD-06` | `dsh` | `Thread` | `steer` | N/A: Thread delivery queues prompt; mid-turn steering is not used in Thread roster | `unsupported` | `0.2.1-rc.5` | `GOAL.md Added 13:36` | Goal 5 | `ThreadChatAndReceiptTests.testThreadConversationViewModelMessageDelivery` |
| `DS-THD-07` | `dsh` | `Thread` | `streaming` | N/A: Thread roster delivers completed messages upon turn finish; token streaming not required | `unsupported` | `0.2.1-rc.5` | `GOAL.md Added 13:36` | Goal 5 | `ThreadChatAndReceiptTests.testThreadConversationViewModelAgentPlainReply` |
| `DS-THD-08` | `dsh` | `Thread` | `readback` | Plugin listens to `session/event` (`turn/end`), extracts final assistant text, posts to thread | `supported` | `0.2.1-rc.5` | `antigravity-cli/2026-11-05_dsh-plugin-adapter.md §2` | Goal 2.3, Goal 5 | `ThreadChatAndReceiptTests.testThreadConversationViewModelAgentPlainReply` |
| `DS-THD-09` | `dsh` | `Thread` | `interrupt` | Cancel/abort via Cordis container lifecycle event | `supported` | `0.2.1-rc.5` | `antigravity-cli/2026-11-05_dsh-runtime.md` | Goal 2.3, Goal 5 | `SessionStreamingAndSteeringTests.testSessionConversationViewModelInterruptSession` |
| `DS-THD-10` | `dsh` | `Thread` | `approvals` | Plugin listens to `approval/asked`, handoff via `achat hook dsh` -> `needs_human` thread event | `supported` | `0.2.1-rc.5` | `antigravity-cli/2026-11-05_dsh-plugin-adapter.md §2` | Goal 2.3, Goal 5 | `SessionStreamingAndSteeringTests.testSessionConversationViewModelApprovalWorkflow` |
| `DS-THD-11` | `dsh` | `Thread` | `model-select` | Applied via Cordis agent configuration | `partial` | `0.2.1-rc.5` | `antigravity-cli/2026-11-05_dsh-runtime.md` | Goal 2.3, Goal 5 | `TriBackendAdapterTests.testCapabilityRegistryRetrievalAndDegradation` |
| `DS-THD-12` | `dsh` | `Thread` | `permission-mode` | Member mode tracked in LightRelay; applied to member context | `supported` | `0.2.1-rc.5` | `Sources/PharosRuntime/LightCommands.swift` | Goal 2.3, Goal 5 | `TriBackendAdapterTests.testDshBackendAdapterStartupParsingAndLifecycle` |
| `DS-THD-13` | `dsh` | `Thread` | `receipts` | 4-phase `delivery.ack` loop (`accepted` -> `injected` -> `consumed` -> `completed`) | `supported` | `0.2.1-rc.5` | `antigravity-cli/2026-11-05_dsh-plugin-adapter.md §3` | Goal 2.3, Goal 5 | `ThreadChatAndReceiptTests.testThreadConversationViewModelReceiptProgression` |
| `DS-THD-14` | `dsh` | `Thread` | `history-backfill` | Mesh room durable mailbox log backfill on join/reconnect | `untested` | `0.2.1-rc.5` | `Sources/PharosRuntime/MeshBroker.swift` | Goal 2.3, Goal 5 | `TriBackendAdapterTests.testDshBackendAdapterStartupParsingAndLifecycle` |
| `DS-THD-15` | `dsh` | `Thread` | `cross-machine` | Mesh packet sent to remote host Pharos node; remote node delivers to local dsh plugin | `untested` | `0.2.1-rc.5` | `GOAL.md Added 13:36` | Goal 5 | `BackendIntegrationTests.testDshRealWebHostIntegration` |
| `DS-THD-16` | `dsh` | `Thread` | `project-cwd` | Single-writer `workspace.json` registered via host node | `supported` | `0.2.1-rc.5` | `antigravity-cli/2026-11-05_integration-matrix.md §4` | Goal 5 | `TriBackendAdapterTests.testDshBackendAdapterStartupParsingAndLifecycle` |
| `DS-THD-17` | `dsh` | `Thread` | `avatars-identity` | Sender avatar seed + member name rendered in thread message bubble | `supported` | `0.2.1-rc.5` | `GOAL.md Added 11:47` | Goal 5, Goal 6 | `ThreadChatAndReceiptTests.testThreadConversationViewModelMessageDelivery` |

---

## 4. Consolidated Pitfalls Cross-Reference

Every pitfall uncovered in the three research archives is indexed below and mapped to the affected checklist rows. All entries are deduplicated and synchronized with `docs/PITFALLS.md`:

| Pitfall ID | CLI & Version | Title / Symptom | Affected Matrix Rows | Workaround / Mitigation in Pharos |
|---|---|---|---|---|
| `PIT-CX-01` | `codex-cli 0.166.0` | In-session model switch unsupported | `CX-SES-11`, `CX-THD-11` | Graceful restart fallback: sends `/quit`, awaits process termination, revives session via `codex resume <id> -m <model>`. |
| `PIT-CX-02` | `codex-cli 0.166.0` | Rollout creation deferred until first prompt in standalone TUI | `CX-SES-04` | Launch sends opening handshake message to trigger rollout creation, then resolves session ID. |
| `PIT-CX-03` | `codex-cli 0.166.0` | WebSocket-over-UDS framing requirement (raw JSONL fails) | `CX-SES-01`–`16`, `CX-THD-05` | Direct WebSocket-over-UDS connection (`WebSocketUDS`) with HTTP/1.1 Upgrade and RFC 6455 masking. |
| `PIT-CX-04` | `codex-cli 0.166.0` | Multi-client subscription isolation on `thread/start` | `CX-SES-02`, `CX-SES-07` | Secondary clients explicitly call `thread/resume` to register their connection ID into `ThreadManager` subscriber set. |
| `PIT-CX-05` | `codex-cli 0.166.0` | Immediate `thread/resume` failure on empty threads | `CX-SES-04` | Defer secondary attachment until first turn completes and rollout record flushes to disk. |
| `PIT-CX-06` | `codex-cli 0.166.0` | First-response-wins approval race across multiple subscribers | `CX-SES-10`, `CX-THD-10` | Pharos acts as single-lease `ApprovalBroker` per thread; secondary clients observe read-only. |
| `PIT-CX-07` | `codex-cli 0.166.0` | Memory-only approval state (`waitingOnApproval`) | `CX-SES-02`, `CX-SES-10` | Track approval state via live daemon subscription (`thread/status/changed`), never filesystem polling. |
| `PIT-CX-08` | `codex-cli 0.166.0` | Lack of monotonic notification sequences or replay | `CX-SES-07`, `CX-SES-14` | On reconnect, reconcile durable state via `thread/turns/list` and `thread/items/list`. |
| `PIT-CX-09` | `codex-cli 0.166.0` | ChatGPT.app uses private stdio; no attachable socket | All Codex rows | Do not attempt to attach to ChatGPT.app. Connect solely to shared daemon control socket. |
| `PIT-CX-10` | `codex-cli 0.166.0` | `thread/list` filters empty threads without preview | `CX-SES-01` | Use `thread/loaded/list` for active threads; populate list locally after `thread/start`. |
| `PIT-CX-11` | `codex-cli 0.166.0` | `thread/shellCommand` runs unsandboxed without approvals | `CX-SES-10`, `CX-SES-12` | Never expose `thread/shellCommand` as generic command channel; use standard `turn/start`. |
| `PIT-CX-12` | `codex-cli 0.166.0` | `ipc.sock` is private desktop IPC, not app-server | All Codex rows | Never send JSON-RPC to `~/.codex/ipc/ipc.sock`. |
| `PIT-CX-13` | `codex-cli 0.166.0` | Multi-process writer lock collision on same `CODEX_HOME` | `CX-SES-03`, `CX-SES-04` | All Pharos clients share single app-server daemon connection rather than launching multiple app-servers. |
| `PIT-AG-01` | `agy 1.5.1` | No local injection channel for active TUI sessions | `AG-SES-05`, `AG-SES-06` | Primary path is `agy acp` (stdio JSON-RPC); TUI is read-only Attached; tmux keystrokes are external fallback. |
| `PIT-AG-02` | `agy 1.5.1` | Stale presence locks persist after process crash | `AG-SES-01`, `AG-THD-02` | Test liveness using non-blocking `flock(LOCK_EX | LOCK_NB)`: `BlockingIOError` = alive; success = stale. |
| `PIT-AG-03` | `agy 1.5.1` | Headless print mode auto-denies permissioned tools | `AG-SES-10`, `AG-SES-12` | Headless modes are OUT of M3. Interactive sessions use `agy acp` with `session/request_permission`. |
| `PIT-AG-04` | `agy 1.5.1` | Flag parsing: `-p` consumes next argument if paired improperly | All agy rows | Format CLI flags as `--print=""` and pair `--input-format` with `--output-format`. |
| `PIT-AG-05` | `agy 1.5.1` | Transcript `created_at` records write time, not turn start | `AG-SES-08`, `AG-THD-08` | Infer turn start from `USER_INPUT`; infer completion from final `PLANNER_RESPONSE` without tool calls. |
| `PIT-AG-06` | `agy 1.5.1` | TUI footer prompt classification (`>` is echoed) | `AG-SES-02` | Check for active footer `? for shortcuts` (idle) vs `esc to cancel` (busy). |
| `PIT-DS-01` | `dsh 0.2.1-rc.5` | Exclusive session writer lock (`session.lock`) | `DS-SES-04` | Never spawn secondary headless process to attach to active session; use in-process plugin or web API. |
| `PIT-DS-02` | `dsh 0.2.1-rc.5` | Headless `--json` is commit-point projection with truncations | All dsh rows | Headless modes are OUT of M3. UI chat uses web API follow stream; Threads uses in-process plugin. |
| `PIT-DS-03` | `dsh 0.2.1-rc.5` | Web API startup token printed once to stdout, not on disk | `DS-SES-03`, `DS-SES-05` | Pharos spawns `dsh web --no-open` in tmux; captures token into volatile memory only (never logged). |
| `PIT-DS-04` | `dsh 0.2.1-rc.5` | `dsh <profile> --help` writes `cordis.yml` to profile root | All dsh rows | Avoid running `--help` in sandboxes; inspect bundled manifests directly. |
| `PIT-DS-05` | `dsh 0.2.1-rc.5` | `pollIntervalMs: 0` disables proactive idle followup | `DS-THD-05` | Thread delivery loop driven by Runtime socket `delivery.poll` -> `agent.followup()` -> `delivery.ack`. |
| `PIT-DS-06` | `dsh 0.2.1-rc.5` | Compressed session logs (`*.v4.jsonl.zstd`) cannot be tailed | `DS-SES-01`, `DS-SES-14` | Read session list and metadata from uncompressed projection cache (`*.json`). |
| `PIT-DS-07` | `dsh 0.2.1-rc.5` | API cookie and mux socket coupled lifecycle (socket close immediately invalidates cookie with 401) | `DS-SES-03`, `DS-SES-04`, `DS-SES-05`, `DS-SES-07` | Retain token in volatile memory; discard expired cookie and perform fresh `GET /connect` to obtain new cookie and spawn new socket. |
| `PIT-DS-08` | `dsh 0.2.1-rc.5` | `interactions=none` hangs approval requests indefinitely without timeout | `DS-SES-10` | Connect with `interactions=answer` and maintain `$events` stream; answer or reject pending requests. |
| `PIT-DS-09` | `dsh 0.2.1-rc.5` | Approvals use `$events` waterfall and `POST /api/$events/result` (not `approval/*` or `userQuestions/answer`) | `DS-SES-10` | Route approvals through `$events` waterfall and resolve via `POST /api/$events/result`. |
| `PIT-DS-10` | `dsh 0.2.1-rc.5` | `session/control` is a read-only projection stream (not interrupt/model-switch) | `DS-SES-09`, `DS-SES-11` | Interruption uses `POST /api/session/cancel`; model switching uses `POST /api/session/selectModel`. |
| `PIT-DS-11` | `dsh 0.2.1-rc.5` | `session/follow` lacks resume cursor (reconnection requires new snapshot and `session/page`) | `DS-SES-07`, `DS-SES-14` | Track highest durable `seq`; on reconnect consume snapshot and backfill missing sequence gaps with `session/page`. |
| `PIT-DS-12` | `dsh 0.2.1-rc.5` | Duplicate `streamId` closes entire mux WebSocket (code 1008) | `DS-SES-07` | Generate UUIDs for stream IDs; track active stream IDs and cancel old stream before re-opening. |
| `PIT-DS-13` | `dsh 0.2.1-rc.5` | `printUrl:false` makes web Host unattachable with no CLI override | `DS-SES-03` | Enforce `printUrl:true` in Pharos-managed profile configuration; verify stdout URL line. |
| `PIT-DS-14` | `dsh 0.2.1-rc.5` | `--port 0` assigns OS port discoverable only in stdout URL line | `DS-SES-03` | Parse dynamically bound port from `dsh web: http://127.0.0.1:<port>/?token=...` on startup. |
| `PIT-DS-15` | `dsh 0.2.1-rc.5` | `SIGINT` exits with code 130 instead of graceful shutdown | `DS-SES-03`, `DS-SES-04` | Always terminate Host using `SIGTERM` (exit 0) and avoid `C-c` in tmux pane. |
| `PIT-CX-14` | `codex-cli 0.166.0` | Commentary phase and reasoning items omitted from SQLite preview index | `CX-SES-08`, `CX-SES-14` | Translate full rollout event stream rather than SQLite preview summaries; raw flags preserved in `rawVendorPayload`. |
| `PIT-AG-07` | `agy 1.5.1` | Tool results decoupled from tool calls across separate transcript journal steps | `AG-SES-08`, `AG-THD-08` | Adapter maintains in-flight tool correlation map by `tool_call_id` to assemble complete `CanonicalToolResult`. |
| `PIT-DS-16` | `dsh 0.2.1-rc.5` | `tool/call` arguments encoded as JSON-stringified payloads rather than structured objects | `DS-SES-08`, `DS-SES-10` | Adapter performs secondary JSON decoding on `arguments`, preserving raw unparsed string in `CanonicalToolCall.rawArguments`. |

---

## 5. Message Model Translation & Semantic Loss Matrix

> [!NOTE]
> Per user decision (Added 2026-11-05 15:00), the Rich Canonical Message Model (`CanonicalTurn`, `CanonicalStep`, `CanonicalBlock`) applies **EXCLUSIVELY to SESSIONS (1:1 direct chat)**.
> In **THREADS (Group Chat Roster)**, messages route directly over the mesh mailbox as plain chat bubbles (`ClientThreadMessage`); agents return only their final committed text with zero intermediate thinking, tool, or step events.

The table below specifies how each backend's wire objects translate into the Pharos Canonical Session Message Model (`docs/MESSAGE-MODEL.md`), detailing fidelity, semantic loss, unmapped gaps, and preservation mechanisms.

| Backend & Version | Wire Entity | Canonical Target Entity | Translation Mechanism | Fidelity | Loss / Unmapped Gaps | Workaround & Preservation |
|---|---|---|---|---|---|---|
| **dsh 0.2.1-rc.5** | `turn/start` / `turn/end` | `CanonicalTurn` | Maps turn number and termination reason (`reason.kind`) | 100% | None | Raw `reason` object preserved in `CanonicalTurn.rawVendorPayload`. |
| **dsh 0.2.1-rc.5** | `step/start` / `step/end` | `CanonicalStep` | Direct mapping of step sequence | 100% | None | Preserved in `CanonicalStep`. |
| **dsh 0.2.1-rc.5** | `assistant-stream` `text-delta` | `CanonicalStreamingDelta` (`.textDelta`) | Real-time token streaming to chat bubble | 100% | None | Ephemeral streaming presentation. |
| **dsh 0.2.1-rc.5** | `assistant-stream` `reasoning-delta` | `CanonicalStreamingDelta` (`.reasoningDelta`) | Real-time reasoning animation | 100% | None | Ephemeral streaming presentation. |
| **dsh 0.2.1-rc.5** | `assistant/message.content[text]` | `CanonicalBlock.assistantText` | Committed text block | 100% | None | Canonical committed text block. |
| **dsh 0.2.1-rc.5** | `assistant/message.content[reasoning]` | `CanonicalBlock.reasoning` | Committed thought block | 100% | None | Canonical committed reasoning block. |
| **dsh 0.2.1-rc.5** | `tool/call` + `tool/result` | `CanonicalBlock.toolCall` + `toolResult` | Correlated via `callId` | 99% | Arguments transmitted as stringified JSON | Secondary JSON parse into `[String: JSONValue]`; raw string in `rawArguments` (PIT-DS-16). |
| **dsh 0.2.1-rc.5** | `$events` `approval/request` | `CanonicalApprovalRequest` (`.toolPermission`) | Waterfall event mapped to modal approval | 100% | None | Resolved via `POST /api/$events/result`. |
| **dsh 0.2.1-rc.5** | `$events` `user-questions/request` | `CanonicalApprovalRequest` (`.structuredQuestionnaire`) | Multi-select questions mapped to interactive form | 100% | None | `intent` (e.g. `plan-review`) directly mapped. |
| **dsh 0.2.1-rc.5** | `projections.values` | `ClientSessionSummary` | Session title, cwd, model metadata | 98% | Custom projections unmapped in UI | Preserved in `ClientSessionSummary.rawVendorPayload`. |
| **Codex 0.166.0** | `turn/started` / `turn/completed` | `CanonicalTurn` | Maps turn ID and completion status | 100% | None | Failure details mapped to `CanonicalError`. |
| **Codex 0.166.0** | `item/agentMessage/delta` | `CanonicalStreamingDelta` (`.textDelta`) | Live text delta stream | 100% | None | Live bubble stream. |
| **Codex 0.166.0** | `item/reasoning/*Delta` | `CanonicalStreamingDelta` (`.reasoningDelta`) | Live reasoning delta stream | 100% | None | Live reasoning stream. |
| **Codex 0.166.0** | `item/completed` (`agentMessage`) | `CanonicalBlock.assistantText` | Committed text block | 98% | `phase` flag (`commentary` vs `final_answer`) | Phase flag preserved in `rawVendorPayload` (PIT-CX-14). |
| **Codex 0.166.0** | `item/completed` (`reasoning`) | `CanonicalBlock.reasoning` | Maps `content` and `summary` | 100% | None | `summary` mapped to optional reasoning header. |
| **Codex 0.166.0** | `item/completed` (`commandExecution`) | `CanonicalBlock.terminalCommand` | Maps command, cwd, exit code, stdout/stderr | 100% | None | Complete terminal card presentation. |
| **Codex 0.166.0** | `item/completed` (`fileChange`) | `CanonicalBlock.filePatch` | Maps file path, patch kind, and diff | 100% | None | Integrated diff presentation. |
| **Codex 0.166.0** | `thread/status/changed` (`waitingOnApproval`) | `CanonicalApprovalRequest` | Approval activeFlag generates modal request | 95% | Memory-only; lacks wire sequence number | Synthetic ID generated; bound to single `ApprovalBroker` lease. |
| **agy 1.5.1** | `session/prompt` (ACP) | `CanonicalTurn` | Prompt lifecycle maps to turn bounds | 100% | None | Turn status resolved via prompt stopReason. |
| **agy 1.5.1** | `session/update` (ACP) | `CanonicalStreamingDelta` | Streaming progress and content chunk | 100% | None | Ephemeral streaming presentation. |
| **agy 1.5.1** | `transcript.jsonl` (`USER_INPUT`) | `CanonicalBlock.userText` | Raw user prompt string | 100% | None | Canonical user block. |
| **agy 1.5.1** | `transcript.jsonl` (`PLANNER_RESPONSE`) | `CanonicalBlock.assistantText` + `reasoning` | Separates `content` from `thinking` | 100% | None | Distinct text and reasoning blocks. |
| **agy 1.5.1** | `transcript.jsonl` (`tool_calls[]`) | `CanonicalBlock.toolCall` + `toolResult` | Correlates tool call with subsequent observation | 95% | Tool results decouple across transcript lines | Adapter tracks in-flight call IDs to merge results into complete block (PIT-AG-07). |
| **agy 1.5.1** | `session/request_permission` | `CanonicalApprovalRequest` (`.toolPermission`) | ACP permission request mapped to modal | 100% | None | Decision returned via ACP JSON-RPC response. |
