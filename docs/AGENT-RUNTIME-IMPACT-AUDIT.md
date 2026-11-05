# Agent Runtime Impact Audit

Status: In progress  
Date: 2026-08-19  
Related: [RFC-003](RFC-003-AGENT-RUNTIME-RPC.md)

## Audit objective

Identify every surface that assumes an agent is a terminal or tmux process, then migrate those surfaces toward the RFC-003 split between persistent conversation, runtime lease, surface attachment, and delivery endpoint.

## Current findings

| Surface | Current authority | Risk | RFC-003 target |
| --- | --- | --- | --- |
| Main dashboard | Mesh roster plus tmux live set | Conflates identity, process and conversation | Dedicated Session control surface backed by Host Runtime RPC |
| Project issues | `Issue.activeSession` stores a tmux name | Issue links become stale when a runtime moves or resumes elsewhere | Link issue to conversation ID; derive current lease |
| Agent stop | Kills a tmux session locally or over SSH | Cannot distinguish detaching a UI from terminating a durable runtime | `runtime.stop` with lease and capability checks |
| Liveness polling | Enumerates local and remote tmux sessions | SSH polling is delayed and absence is ambiguous | Runtime event subscription with reconnect cursor |
| Dock/menu counts | Count tmux processes or Mesh members | Duplicate and inconsistent counts | Count canonical conversations by runtime state |
| Historical sessions | Reads Claude/Codex files per project | Local-only, no DSH, no remote ownership metadata | `conversation.list` through drivers |
| Resume | Opens vendor CLI in a terminal and may recreate tmux | Creates another seat without canonical lease reconciliation | `conversation.resume`, then `surface.attach` |
| Claude hooks | Hook registration plus pane/session rebinding | Compact, clear and resume can repeat lifecycle events | Idempotent registration keyed by vendor session ID |
| Codex Desktop/TUI | Not a supported Pharos attachment boundary | App Server ownership and protocol drift are ambiguous | Capability-gated Codex driver; no Desktop interception by default |
| DSH web | Separate web runtime and plugin identity | Easiest integration but currently not canonical | Plugin registers with local Host Runtime and exposes follow-up capability |
| ACP | Not currently an execution authority | Mistaking ACP for routing loses mailbox semantics | Optional driver behind the same runtime RPC |
| Broker delivery | Broker mailbox and Mesh member ID | Must not be coupled to a transient surface | Remains durable routing authority |

## UI migration started

The macOS app now has a first-class Agent Sessions surface. Its interim adapter deliberately exposes three distinct datasets:

- Registered runtimes from the Broker roster.
- External fallback transports discovered through legacy tmux polling.
- Persistent Claude and Codex archives discovered from local vendor stores.

The panel reuses current launch/resume/stop functions only as compatibility actions. Labels identify fallback behavior; they are not evidence that Host Runtime RPC has been implemented.

## Required contract migration

1. Introduce stable `conversationID`, `runtimeLeaseID`, `surfaceID`, and `deliveryEndpointID` types.
2. Add Host Runtime RPC schemas and event cursors before replacing any existing authoritative path.
3. Build read-only adapters for Codex, Claude and DSH; compare their output with the interim panel.
4. Move issue linkage from tmux names to conversation IDs with a reversible registry migration.
5. Route new/resume/stop through capability-gated drivers.
6. Replace polling counts only after RPC reconnect and daemon-restart recovery are proven.
7. Retire tmux poke last; keep it as an explicitly external fallback during migration.

## Non-negotiable invariants

- Broker member ID remains identity; nick and tmux metadata are aliases or transport details.
- Mailbox delivery, routing, queueing and idempotency remain Broker/orchestrator responsibilities.
- Compact, clear, resume and client reattachment must not duplicate a conversation registration.
- Closing a TUI or Desktop surface must not implicitly terminate a managed runtime.
- An unsupported vendor client is `External`; Pharos must not claim reliable activation.

## Integration asset conclusions

| Asset | Reuse decision | Main change |
| --- | --- | --- |
| `skills/mesh` | Reuse and simplify | Remove tmux wake guarantees; prefer Runtime RPC spawn/attach |
| `skills/pharos` | Reuse | Keep project/task behavior independent from runtime transport |
| Claude hooks | Reuse as adapter | Emit idempotent lifecycle facts; inject mailbox only as fallback |
| Codex hooks | Reuse as adapter | Treat compact/resume as epochs, not duplicate registration |
| `dsh-plugin-pharos` | Promote to reference driver | Replace polling CLI bridge with socket registration and pushed delivery |

Detailed findings and the normative migration order now live in RFC-003 under
"Integration asset audit."

## iOS impact

As of 2026-08-20, the first authenticated Broker-to-Host Runtime gateway is
implemented. It uses the existing durable Node command queue and exposes only a
three-method remote allow-list. The iOS transport can submit and await these
commands without SSH, tmux, a Host Unix socket, or a vendor WebSocket. Runtime
event cursor forwarding and the session transcript UI are not yet authoritative.

The Host Runtime now persists a bounded event journal and exposes cursor/resume
over the same gateway. A Pharos-owned Codex stdio driver is implemented without
attaching to Desktop's private daemon. The remaining Codex audit gates are
approval-response routing, notification-to-portable-event normalization,
multi-surface turn serialization, and compatibility checks across CLI upgrades.

The existing iOS topology is safe to evolve: spawn and stop already travel
through the Broker's durable Node command queue, and the phone never SSHes for
lifecycle operations. The old UI nevertheless treated each Mesh member and
tmux pane as the session itself.

The first migration slice renames the workspace to Sessions, classifies current
Broker records as Attached or External, and labels SSH/tmux controls as legacy
fallback transport. It does not fabricate Managed or historical conversations.

The remaining iOS gate is a Broker-to-Host Runtime gateway with authenticated,
capability-gated list/read/resume/attach/stop/approval methods and event cursors.
Only after that gateway lands may iOS present Runtime snapshots as authoritative.
