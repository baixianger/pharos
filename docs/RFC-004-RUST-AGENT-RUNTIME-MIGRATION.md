# RFC-004: Rust Agent Runtime Migration

Status: Accepted, phase 3 in progress

## Decision

Pharos will converge on a Rust-owned Agent Runtime. SwiftUI clients remain
presentation surfaces and use stable RPC contracts; they do not implement
vendor transports or own durable agent processes.

The migration is incremental because the current broker, Mesh node and Runtime
Host are SwiftPM modules. Replacing all three at once would mix transport,
routing and persistence changes and make cross-device regressions difficult to
isolate.

## Process and routing model

Pharos uses a client/server architecture. macOS, iOS, and web applications are
replaceable frontend skins. They do not own agent processes, queues, registry
state, or routing state. Installing the macOS frontend also installs an
independent, long-lived Rust backend named `pharos-meshd`.

`pharos-meshd` is authoritative for sessions owned by its Host. Mesh Node, Broker,
hooks, skills, and provider adapters depend on or register with `pharosd`; they
must not be parents or lifecycle owners of it. Closing a frontend or restarting
a Mesh Node therefore does not terminate an agent session.

A frontend can reach a target Host through two equivalent transports:

1. Direct: the frontend connects to the target Host's `pharos-meshd`. This is
   semantically local operation with the control surface rendered elsewhere.
2. Broker: the frontend connects to its local or Home `pharos-meshd`, and the
   Broker forwards the request to the target Host's `pharos-meshd`.

The user chooses a target Host, not a transport. Automatic routing prefers a
healthy direct path and falls back to Broker routing. Advanced policy may force
direct-only or broker-only behavior. Both transports carry the same Request ID,
idempotency key, Frontend ID, target Host ID, adapter ID, and provider session
ID. The target Host is authoritative and performs final deduplication. Broker
mailboxes queue while a Host is offline; the target Host action queue serializes
work while an agent is busy.

This model deliberately avoids an all-to-all replicated database or CRDT. The
Broker transports and indexes messages; it does not own remote agent state.

## Target layout

```text
rust/crates/
  agent-core/       shared request, response and capability contracts
  adapter-codex/    Codex daemon, proxy, WebSocket and App Server JSON-RPC
  agent-runtime/    `pharos-meshd`: registry, queues, events and Unix RPC host
  adapter-claude/   future official-surface integration
  adapter-dsh/      future embedded DSH integration
```

## Phase 1

Implemented:

- `pharos-agent-core` owns the sidecar IPC envelope.
- `pharos-codex-adapter` resolves the Codex executable without a login-shell
  `PATH`, starts the shared daemon, connects through the official proxy,
  performs the WebSocket upgrade and initializes App Server JSON-RPC.
- The Swift Codex driver is a thin, persistent JSONL IPC client.
- App packaging embeds and signs the Rust helper.
- MeshNode installation copies the helper beside the long-lived node binary so
  replacing or quitting the GUI does not invalidate the runtime.

## Phase 2

Implemented:

- `pharos-agent-runtime` owns the adapter registry and a serialized worker
  queue, preventing concurrent clients from interleaving vendor transport.
- It exposes JSONL stdio for the Swift compatibility facade and a private Unix
  socket host for direct contract testing and future cutover.
- Generic adapter discovery, capability negotiation and session actions are
  handled in Rust. Unsupported actions return explicit errors.
- The Swift Codex driver starts the Rust Runtime rather than the Codex transport
  directly.

## Remaining migration

Phase 3 moves event journaling and the public Unix RPC listener into Rust. It
also installs `pharos-meshd` as a LaunchAgent independent of the GUI and Mesh Node.
The Swift Runtime Host and vendor adapter implementations can be removed after
local, LaunchAgent and remote Mesh routes pass the same contract suite.

Codex server notifications and server-initiated requests such as approvals or
elicitation require a duplex event channel before Pharos may claim full turn
driving. Phase 1 intentionally supports discovery and request/response methods;
it must not silently treat unsupported interactive flows as delivered.

## Claude and DSH adapters

Claude uses the public MCP Channel contract for external delivery. Pharos does
not depend on Claude Code's undocumented inbox-socket message frames. A channel
process registers its exact Claude session with `pharos-meshd`, polls the Host
delivery queue, and emits `notifications/claude/channel`. Because custom
Channels remain a research preview, sessions that did not opt in expose
visibility but no direct-delivery capability.

DSH integrates in-process through a Cordis plugin. Every live
`agent.session.id` is registered as a distinct conversation; the Web process is
only a container. The plugin polls queued delivery and calls `agent.followup()`.
Its acknowledgement means durable inbox admission, never prompt-specific turn
completion. Neither adapter invents fork, restart, interrupt, or completion
capabilities absent from its provider surface.

## Validation gates

- Rust unit and contract tests.
- Swift build and existing Runtime RPC tests.
- Signed App packaging with architecture and code-sign checks.
- LaunchAgent installation copies the matching Rust helper.
- A request sent to the live Runtime socket reaches the shared Codex daemon and
  returns a real session.
- Before Phase 3, repeat the contract suite through a second Mesh host.
