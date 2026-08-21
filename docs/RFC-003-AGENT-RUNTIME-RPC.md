# RFC-003: Agent Runtime RPC and Persistent Conversations

> Implementation update (2026-08-20): `agent-runtime-gateway-v1` now reuses the
> authenticated, durable Broker Node-command route. A Host forwards only
> `runtime.hello`, `runtime.snapshot`, and `delivery.submit` to its private Unix
> socket. iOS has a matching client and never receives a vendor endpoint. Event
> cursors and native Codex/DSH turn adapters remain the next implementation step.

> Codex driver update (2026-08-20): the Host Runtime now has a lazy, Pharos-owned
> stdio adapter for the installed Codex App Server (`0.147.0` on the development
> host). It initializes as a distinct client and maps list/read/start/resume/fork
> plus turn start/interrupt behind Pharos method names. Codex notifications and
> server requests enter a bounded, persisted Host event journal with reconnect
> cursors. Approval responses and normalized transcript projection remain open.

Implementation impact is tracked in [Agent Runtime Impact Audit](AGENT-RUNTIME-IMPACT-AUDIT.md).

## Implementation status

The first implementation slice is active on `feat/agent-runtime-rpc`:

- The persistent Host Node now owns a same-user Unix-socket JSON-RPC server.
- Driver, conversation, surface, snapshot, and delivery queue contracts are implemented.
- Registry state is persisted atomically with user-only filesystem permissions.
- DSH registers its driver, capabilities, conversation, and Web surface when the Runtime is present.
- DSH retains its existing Mesh polling and `agent.followup()` path when Runtime registration fails.
- macOS and iOS expose a unified Session surface without claiming that the Broker gateway is complete.

The iOS app is a remote presentation surface. It never connects to the Host's
Unix socket. Its current Broker roster is labelled as Attached or External;
Managed conversations and archives require the next protocol slice:
Broker request → durable Node command → Host Runtime RPC → Broker response/event.

## Integration asset audit

This RFC covers not only the daemon and UI. Existing Skills, vendor hooks, and
the DSH Cordis plugin are protocol adapters that must move with the runtime
boundary. The audit below is normative for migration.

### Skills

The `mesh` and `pharos` Skills remain useful because they encode portable agent
behavior: exact identity use, bounded mailbox drains, explicit routing, evidence
reporting, and conservative handling of unsupported clients. They must not be
the runtime control plane.

Current problems:

- The Mesh Skill still promises that an `@mention` wakes an agent through tmux.
- Passive join treats raw tmux and SSH recipes as the normal spawn mechanism.
- Session discovery, room membership, process creation, and activation are
  described as one agent-operated procedure.
- A Skill can be skipped, compressed out of context, or interpreted differently
  by different vendors; it cannot establish lifecycle authority.

Required revision:

- Keep routing etiquette, member-ID rules, mailbox semantics, and task-triage
  guidance transport-neutral.
- Replace the preferred passive-join path with `runtime.spawn`,
  `conversation.resume`, and `surface.attach` RPC operations.
- Move raw tmux/SSH instructions into an explicitly labelled External fallback
  appendix with no reliable-delivery claim.
- Let the Host Runtime supply conversation and member identities. A Skill may
  consume those identities but must never derive one from cwd, nick, pane, or a
  tmux session name.
- Capability discovery determines whether activation is native, hook-assisted,
  or mailbox-only. The Skill must not guess from the agent brand.

Decision: **reuse and simplify**. Skills remain the portable behavioral layer;
all lifecycle and activation authority moves below them.

### Claude and Codex hooks

The current hook set observes SessionStart, turn boundaries, tool activity,
permissions, compaction, failures, and SessionEnd. This is valuable coverage and
should be reused. The current implementation also records pane-local context,
rebinds a predecessor on clear/resume, injects unread notices at Stop and
PostToolUse, and shells through the Pharos CLI with a ten-second timeout.

Target role:

- Hooks emit idempotent lifecycle facts to the local Host Runtime over its Unix
  socket. They are sensors, not the source of conversation ownership.
- Registration is keyed by `(driver, vendorSessionID)`. Repeated SessionStart,
  resume, clear, compact, project-level plus user-level hook installation, and
  daemon reconnects must converge on one record.
- Compact updates a conversation/runtime epoch; it does not create or rejoin a
  member. Clear creates a new vendor conversation only when the vendor supplies
  a new stable ID. Resume reattaches to the matching conversation ID.
- Pane/socket/cwd metadata may help diagnose or attach an External surface, but
  may not transfer mailbox or conversation ownership.
- Stop and PostToolUse context injection remains only for drivers that lack
  native wake/submit capability. Managed drivers receive delivery through the
  runtime driver and acknowledge it with delivery IDs.
- Hook failure remains fail-open for the vendor agent. The runtime records stale
  telemetry rather than inferring that the conversation ended.

Decision: **reuse as a compatibility adapter**. Do not remove hooks until each
vendor driver provides equivalent lifecycle and delivery evidence. Do not build
new architecture on tmux rebind.

### DSH Cordis plugin

The existing `dsh-plugin-pharos` is the strongest candidate for the first native
Host Runtime driver. It already:

- Uses `agent.session.id` as the immutable member identity.
- Derives aliases without truncating the source identity before hashing.
- Reconciles room membership idempotently and guards leave by member ID.
- Separates mailbox peek from consume.
- Uses DSH's in-process `agent.followup()` to activate an idle agent.
- Registers native Cordis tools without importing a competing tool-registry
  version.

The current implementation is still a bridge, not a complete driver:

- It forks the Pharos CLI for every operation and polls every three seconds.
- One global `pollInFlight` serializes all agents in the web process.
- A member-level `notified` flag has no message cursor; additional mail arriving
  while unread remains nonzero can be coalesced indefinitely.
- `followup()` injects a prompt telling the agent to call recv, adding another
  model/tool round rather than delivering an acknowledged envelope.
- Process disposal leaves the room, conflating one DSH surface/process lifetime
  with the persistent conversation lifetime.
- It does not register capabilities, runtime leases, surface attachments, or
  reconnect epochs with Pharos.

Required DSH driver behavior:

1. On plugin startup, discover the local Pharos Host Runtime socket. If present,
   register the DSH driver and its capabilities.
2. Register each `agent.session.id` as a conversation/runtime attachment using
   an idempotency key and reconnect epoch.
3. Subscribe once per web process; let Pharos push delivery envelopes instead
   of spawning polling CLIs per agent.
4. Activate the target with `agent.followup()` and acknowledge accepted,
   injected, consumed, and completed states by delivery ID.
5. Treat `agent/disposed` as runtime/surface detachment. Archive or leave rooms
   only when the orchestrator explicitly ends the conversation.
6. Keep current CLI polling as a conservative fallback when no compatible Host
   Runtime is available. Report the endpoint as External and do not promise
   exactly-once wakeup.
7. Preserve Cordis-native tools, but route them over runtime RPC when available.

Decision: **make DSH the reference native integration**. It proves the driver
contract before the less controllable Claude and Codex client combinations.

### Adapter capability matrix

| Adapter | Stable vendor session ID | Native activation | Lifecycle observation | Target class |
| --- | --- | --- | --- | --- |
| DSH Cordis | Yes, `agent.session.id` | Yes, `agent.followup()` | In-process events | Managed |
| Claude hooks only | Yes, hook session ID | No guaranteed submit channel | Broad hook coverage | Attached |
| Claude peer socket | Yes, when available | Capability-gated | Socket plus hooks | Managed or Attached |
| Codex hooks only | Yes, thread/session ID | No guaranteed submit channel | Native hook coverage | Attached |
| Codex App Server | Yes, conversation/thread ID | Protocol command | App Server events | Managed |
| ACP adapter | Protocol-dependent | Protocol-dependent | Protocol-dependent | Managed when proven |
| tmux fallback | No; seat metadata only | Keystroke injection | Process/pane polling | External |

### Migration order for integration assets

1. Freeze new tmux-dependent behavior and revise Skills to describe capability
   classes rather than brands.
2. Define lifecycle-fact, registration, capability, delivery-envelope, and
   acknowledgement RPC schemas.
3. Convert DSH to the reference native driver while retaining its CLI fallback.
4. Point Claude/Codex hooks at the local Runtime event endpoint and add runtime
   idempotency across clear, compact, resume, and duplicate hook scopes.
5. Add managed Codex App Server and capability-gated Claude peer adapters.
6. Remove Stop/PostToolUse mailbox injection only for sessions whose active
   driver proves native activation and acknowledgement.
7. Keep Skills and hooks available for user-started External sessions; remove
   tmux poke from the reliability contract.

- Status: Proposed
- Date: 2026-08-19
- Implementation status: Pending
- Supersedes: tmux poke as the target activation transport

## Context

Pharos currently launches coding agents as terminal processes and uses hooks,
mailboxes, and tmux keystroke injection to wake some idle sessions. That path
proved the product value, but terminal state is not a reliable agent control
plane:

- A terminal window is a presentation surface, not a conversation identity.
- Pane text and process liveness do not establish agent lifecycle state.
- Keystroke injection can collide with prompts, approvals, or user input.
- A closed TUI should not destroy a persistent agent conversation.
- Desktop, TUI, mobile, and Pharos may all need to view the same runtime.
- Vendors expose different control protocols, so ACP alone cannot be the
  universal routing and mailbox layer.

The vendor capabilities investigated for this decision are:

| Vendor | Native control path | Native presentation surfaces |
|---|---|---|
| Codex | App Server JSON-RPC | Remote TUI, custom clients, Remote Control; Desktop shared-daemon attachment is capability-gated |
| Claude Code | Per-session peer inbox and Channels | Claude TUI, Agent View, Remote Control |
| DSH | Cordis plugin and `agent.followup()` | `dsh web` |
| ACP agents | ACP session connection | Vendor or third-party ACP clients |

## Decision

Pharos will become a general agent integration platform with four separate
layers:

```text
Pharos Broker
    durable routing, mailbox, idempotency, cross-host identity
        |
Pharos Host Runtime
    process supervision, runtime leases, driver registry, RPC
        |
AgentRuntimeDriver
    Codex, Claude, DSH, ACP, conservative external fallback
        |
Presentation surfaces
    Pharos UI, native TUI, vendor web/desktop/mobile clients
```

Pharos owns the control plane. Vendor applications may continue to own their
presentation surfaces. tmux is not part of the target delivery architecture.

## Why RPC fits this boundary

The Host Runtime is long-lived while every UI is transient. It must accept
commands from the macOS app, CLI, Broker delivery worker, iOS client, and native
surface adapters while streaming lifecycle events back to those clients. That
is an RPC problem, not a shell-command or terminal-control problem.

Pharos will define a typed JSON-RPC control protocol with:

- Unix domain sockets for same-user local clients.
- Request/response methods for lifecycle mutations and queries.
- JSON-RPC notifications for ordered runtime and turn events.
- A protocol-version and capability handshake.
- Request IDs and idempotency keys for retry-safe mutations.
- Event sequence numbers and cursors for reconnect catch-up.
- Existing authenticated Broker/Host transport for cross-machine forwarding.

JSON-RPC is preferred over inventing a binary protocol because Codex App Server
already uses the same interaction model, Swift can model the envelopes with
`Codable`, and the protocol needs inspectability during vendor integration.
Vendor JSON-RPC frames are not exposed directly as the Pharos contract.

The Broker message bus and Host RPC remain distinct:

```text
Broker: who should receive this durable message?
Host RPC: how should this local runtime be loaded and activated?
Vendor driver: which native protocol call performs that activation?
```

## Persistent data model

### AgentConversation

A durable user-visible conversation, independent of process and UI lifetime:

```text
id
memberID
vendor
vendorConversationID
projectID
cwd
title
model
createdAt
lastActivityAt
lastSummary
resumeCapability
```

### RuntimeLease

One loaded execution instance of a conversation:

```text
conversationID
runtimeID
generation
driver
hostID
pid
endpointReference
state
startedAt
lastSeenAt
```

Endpoints and credentials are host-local secrets. They are never copied into
portable Broker project data.

### SurfaceAttachment

A transient UI connected to a runtime:

```text
runtimeID
surfaceKind
surfaceInstanceID
connectedAt
approvalOwner
```

Closing a TUI removes an attachment. It does not delete the conversation.

### DeliveryEndpoint

The currently usable activation path and its guarantees:

```text
runtimeID
driver
capabilities
leaseGeneration
deliveryMode
```

Delivery modes are `native`, `deferred`, and `unavailable`.

## Runtime ownership classes

| Class | Meaning | Delivery guarantee |
|---|---|---|
| Managed | Pharos owns the runtime and endpoint | Native activation, recovery, and event stream |
| Attached | A plugin or hook registered an externally owned runtime | Capability-dependent; may be deferred |
| External | Pharos can see stored history but has no live endpoint | No activation guarantee |

Pharos routes only to a live `DeliveryEndpoint` with a matching lease
generation. A stored thread ID alone never proves that a runtime is safe to
drive.

## Proposed RPC surface

The first protocol version should expose these method groups:

| Group | Representative methods |
|---|---|
| Conversation | `conversation/list`, `conversation/read`, `conversation/create`, `conversation/resume`, `conversation/fork`, `conversation/archive` |
| Runtime | `runtime/load`, `runtime/read`, `runtime/stop`, `runtime/reconcile`, `runtime/capabilities` |
| Surface | `surface/attach`, `surface/detach`, `surface/list` |
| Delivery | `delivery/submit`, `delivery/read`, `delivery/cancel` |
| Approval | `approval/read`, `approval/resolve` |
| Subscription | `events/subscribe`, `events/resume`, `events/unsubscribe` |

Representative notifications include:

```text
conversation/updated
runtime/stateChanged
runtime/leaseChanged
surface/attached
surface/detached
delivery/accepted
delivery/consumed
turn/started
turn/completed
approval/requested
approval/resolved
```

The public Pharos RPC describes portable concepts. Driver-specific methods stay
behind the Host Runtime boundary.

## Delivery semantics

The Broker remains authoritative for directed messages. A wake request contains
message references, not a second authoritative copy of the mailbox:

```json
{
  "memberID": "member-id",
  "generation": 12,
  "deliveryID": "delivery-id",
  "roomID": "room-id",
  "unreadCount": 3,
  "newestMessageID": "message-id",
  "busyPolicy": "queue"
}
```

The driver injects a bounded instruction to drain the exact mailbox. The Agent
then consumes messages through its immutable Pharos member identity.

Delivery states are distinct:

```text
stored -> accepted -> queued or injected -> consumed
                                  |
                                  -> failed or expired
```

The default busy policy is `queue`. Steering an active turn requires an explicit
message policy. Agent messages never inherit human approval authority.

## Driver decisions

### Codex

The supported target topology is one Pharos-managed, persistent Codex App Server
daemon per host/security profile:

```text
Codex App Server daemon
    +-- Pharos control client
    +-- codex --remote TUI
    +-- Pharos macOS/iOS clients
    +-- ChatGPT Remote when remote control is enabled and paired
    +-- Codex Desktop when shared-local-daemon capability is available
```

Pharos stores the non-ephemeral Codex `thread.id`. A detached or unloaded thread
is restored with `thread/resume`; idle activation uses `turn/start`; explicit
mid-turn steering may use `turn/steer`.

Codex Desktop currently has two modes:

- Its normal local mode owns a private stdio App Server and is not externally
  addressable. Hooks can register the thread as Attached, but delivery is
  deferred until a later hook boundary.
- Current builds contain an undocumented, experimental shared-local-daemon path
  using `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1` and the managed control socket.
  Pharos may probe this capability, but must not require it without versioned
  validation.

If Desktop shared-daemon attachment is unavailable, Pharos guarantees only its
own UI and the official remote TUI as frontends. It does not fall back to tmux.

### Claude Code

Claude Code supports native cross-session messaging with per-session inbox
sockets. Pharos will prefer a version-gated native peer driver when its external
wire contract is proven, use an official Channel adapter as fallback, and use
hooks for registration and deferred delivery.

`SessionStart` is a reconciliation event, not a create event. It can fire for
`startup`, `resume`, `clear`, and `compact`. Registration is an upsert keyed by
vendor session identity plus runtime generation. Compaction must never create a
second Pharos member.

### DSH

DSH is the simplest native adapter. The Cordis plugin connects to the local
Pharos Host Runtime, registers every `agent.session.id` separately, keeps an
event subscription, and calls `agent.followup()` for directed delivery. The
`dsh web` process is a runtime host, not a shared agent identity.

### ACP

ACP is a driver for agents that implement it. It is not Pharos routing, mailbox,
lease, or concurrency control. ACP answers how to drive a compatible session;
the Pharos Broker still answers who receives a message.

## Session browser product model

Pharos will show persistent conversations across vendors rather than only live
terminal processes. Starting an agent offers `New`, `Resume`, and `Fork`.

Each row displays:

```text
vendor
project
title
managed/attached/external
working/needs-input/idle/sleeping/stopped
attached surfaces
delivery capability
last activity
```

Vendor-native surfaces remain optional actions:

```text
Open in Pharos
Open in native TUI
Open in vendor web or desktop client when supported
Resume in background
Fork
Archive
```

## Security

- Local RPC sockets live in a user-private directory with restrictive modes.
- The Host validates same-user peers where the platform exposes peer identity.
- Secrets and endpoint tokens stay in host-local credential storage.
- Every runtime mutation checks the current lease generation.
- Approval resolution is scoped to one request and one authorized surface.
- Agent-originated messages are lower authority than human-originated requests.
- Cross-host RPC uses the existing authenticated Host route rather than exposing
  a new unauthenticated LAN listener.

## Migration

1. Define the RPC schema, version handshake, event cursor, and persistence model.
2. Implement the Host Runtime and DSH driver first.
3. Implement the managed Codex App Server driver and remote TUI attachment.
4. Probe Codex Desktop shared-daemon attachment behind a capability flag.
5. Implement Claude registration, Channel fallback, then native peer delivery.
6. Add the unified conversation browser and `New`/`Resume`/`Fork` flows.
7. Remove tmux delivery, pane probing, and keystroke injection after native
   drivers cover supported agents.

During migration the shipped tmux path remains legacy behavior, not the target
contract. New architecture must not add further dependencies on pane state.

## Consequences

Positive consequences:

- UI lifetime no longer controls agent lifetime.
- Multiple frontends can attach to one managed runtime.
- Conversations can be resumed across app restarts and machines.
- Delivery guarantees are explicit per runtime rather than inferred from panes.
- New vendors integrate through one Driver interface.

Costs and risks:

- The Host Runtime becomes a real local service with protocol compatibility
  responsibilities.
- Multi-client approval ownership and reconnect behavior need explicit tests.
- Vendor experimental capabilities require version probes and conservative
  fallback.
- Desktop clients that keep private, unreachable backends remain Attached with
  deferred delivery until vendors expose a supported attachment path.
