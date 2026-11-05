# RFC-006: Unified Client and Backend Integration

- Status: Proposed
- Date: 2026-11-05
- Builds on: [RFC-003](RFC-003-AGENT-RUNTIME-RPC.md) (driver / conversation / surface / delivery contract), [RFC-005](RFC-005-LIGHTWEIGHT-AGENT-MESSAGING.md) (member registry, point-to-point threads)
- Replaces: the old macOS UI (abandoned, deleted once the new client reaches parity)
- Companion docs: [BACKEND-MATRIX.md](BACKEND-MATRIX.md), [MESSAGE-MODEL.md](MESSAGE-MODEL.md), [PITFALLS.md](PITFALLS.md), [ARCHITECTURE-AUDIT.md](ARCHITECTURE-AUDIT.md)

## Problem

The owner runs many agents (Codex, Antigravity, dsh, and more later) across several Macs. Each agent has its own front end and its own way of being driven. The owner wants one place to see every live session, talk to any of them, run group conversations between agents, and track projects across machines.

## Decision

Pharos becomes **one unified, native SwiftUI front end over many agent back ends**. It does not replace the vendors' runtimes. It connects to the long-running service each vendor already has, translates what it sees into one model, and presents it in one client.

### 1. Two interaction modes, and only two

1. **Session.** In the generic Session view the human talks directly to one agent session, over the mesh. The client sends to the Pharos node on the host that owns the session. That node drives the vendor's central service locally and streams events back over the mesh. Local and remote hosts use the same path.
2. **Thread.** The human posts in a group conversation and addresses specific agents. Threads follow RFC-005: point-to-point deliveries over the mesh, reply inheritance, participants derived rather than stored.
   - The human is an **implicit, invisible participant of every thread** by default. They are not listed in the roster, but they can always post, they receive every message and reply, and they are the default reply target. No join step is needed.
   - Thread messages are plain messages with no tool calls. They render as simple chat bubbles: sender, avatar, text, timestamp, optional links or attachments, and a delivery receipt. An agent's thread reply is its final text only.

The same agent can have a 1:1 session and take part in threads. The two histories are separate resources and never mix.

### 2. Every back end has a central service, and Pharos is another client of it

| Back end (version researched) | Session path | Thread path | Process hosting |
|---|---|---|---|
| Codex (codex-cli 0.166.0) | Shared app-server daemon at `~/.codex/app-server-control.sock` (WebSocket over a Unix socket). `turn/start`, `turn/steer`, streamed notifications, `thread/turns/list` to backfill after reconnects. Pharos is the designated approval owner. | Same daemon connection: `turn/start` into the member's own thread, then the final reply goes back to the thread with a receipt. | None needed. The daemon is self-managed, detached from any terminal, and outlives the CLI TUI. Sessions show as `notLoaded` after a daemon restart and must be resumed first. |
| dsh (0.2.1-rc.5) | A persistent `dsh --profile web --no-open --host 127.0.0.1 --port <fixed>` Host kept alive in tmux. `/api/session/*` for prompt, steer, control, approvals and models; `session/follow` on `/api/remote.mux` for streaming. The launch token stays in memory only and is never logged. | `dsh-plugin-pharos`, running in-process: `delivery.poll` → `agent.followup()` → `delivery.ack`. The plugin is only for exchanging messages with other agents. It is not the Session path. | tmux. |
| Antigravity (agy 1.5.1) | `agy acp` (stdio JSON-RPC), held by the headless Pharos backend daemon. `session/prompt` (with mid-turn append), `session/update`, `session/request_permission`, `session/set_config_option` for models. | Same ACP connection: the message is delivered into the member's session, then the final reply goes to the thread with a receipt. | The backend daemon holds the child process. The tmux TUI with transcript read-back stays as the fallback. |

Not attachable, and not pursued:

- **ChatGPT.app's Codex.** Codex Framework 156.0.8078.79 runs a private stdio app-server. Pharos reads its sessions from disk only.
- **A running agy TUI.** Its internal RPC requires a CSRF token that is not available outside the process.
- **The user's own dsh web Host.** Its token is not persisted, so Pharos starts and owns its own Host instead.

Headless modes (`dsh --profile headless`, `agy` print / stream-json) are out of scope for now and will be researched later.

Cross-machine rule: vendor state stays on the host that produced it. Remote work is always sent to that host's Pharos node, which calls the vendor locally. Pharos never opens a vendor socket across machines.

### 3. One canonical message model for Sessions

- Sessions use one versioned, canonical event model: turns, steps, thinking, text, tool calls and results, approvals and questions, model and status changes, errors, attachments. The dsh web session view is the visual and structural reference.
- Each back end has a translation layer in its adapter. dsh maps nearly losslessly. Codex items and agy ACP updates are translated.
- Anything that cannot be mapped is kept as a raw vendor payload next to the canonical event. Nothing is silently dropped.
- The model supports streaming deltas plus committed blocks, and stable ids for reconnects and backfill.
- Threads do not use this model. They have their own small message DTO (section 1).

Details: [MESSAGE-MODEL.md](MESSAGE-MODEL.md).

### 4. Strict client / backend isolation

- The SwiftUI client is a thin presentation layer. It never shells out and contains no delivery, tmux, CLI, SSH, mesh, broker or transcript-parsing code.
- All traffic goes through **one versioned client API**: Codable DTOs plus an event stream, documented in `docs/CLIENT-API.md`. The client can be built and previewed against a mock implementation.
- Backend modules (runtime, mesh, messaging, adapters) never import SwiftUI or AppKit. They run fully headless as CLI plus daemon, and are testable without the app. The app can be killed and restarted without affecting live sessions.
- This is enforced by `Package.swift` target dependencies plus an automated layering check that fails on forbidden imports. Current violations are listed in [ARCHITECTURE-AUDIT.md](ARCHITECTURE-AUDIT.md).
- Performance rule: the backend coalesces events before pushing them to the UI. It must not trigger a redraw per token.

### 5. The client

The client is a native SwiftUI three-pane app. Its layout and interaction are modelled on the owner's Grok Bot UI research archive (`~/brainstorm/collections/design/grok-bot/` on the Mac mini).

- **Left pane.** Three tabs:
  - **Sessions:** every live session across all machines; open one to chat directly.
  - **Threads:** group conversations with sender avatars and a composer for the human.
  - **Projects:** every registered project with per-device tracking.
- **Middle pane.** The conversation: the canonical Session view, or the Thread bubbles. The thread bubble and composer style follows the research's chat window.
- **Right pane.** Details, with Library and Computer tabs.
- **Avatars.** Every session or member gets a random Pharos-original avatar from a deterministic seed stored in member info. The owner can change it (shape, colour or upload), and the change is synced through the broker/mesh.

The repository is public. The research is used for layout and interaction ideas only: no copied code, assets, fonts or verbatim design tokens. Pharos has its own palette and avatar renderer.

### 6. Defaults

- Members that Pharos launches or revives default to skip-approval (yolo) mode. A safe mode can be chosen per member; the choice is persisted and shown in the member list.
- Models are switched manually per member. Automatic switching on quota exhaustion is not implemented yet.

### 7. Version pinning and drift

- [BACKEND-MATRIX.md](BACKEND-MATRIX.md) is the source of truth. It has one row per back end × mode × feature, with the mechanism, status, researched version, evidence and the test that proves it.
- Each adapter checks the back end's version when it connects. On an unknown version it warns and degrades to the capabilities marked safe.
- Every CLI defect or unsupported feature goes into [PITFALLS.md](PITFALLS.md) with the CLI name and version, the symptom, repro steps, the impact on Pharos and the workaround. Features are never forced or silently skipped.

Research archives (owner's Mac mini, `~/brainstorm/collections/research/`): `antigravity-cli/`, `codex/`, `dsh-web/`.

## Acceptance

A feature is done when its BACKEND-MATRIX rows flip to supported with evidence, `swift test` is fully green, and a live end-to-end test has passed that includes at least one cross-machine operation between the Mac mini and the MacBook Air.

## Non-goals (for now)

- Headless back-end modes.
- Attaching to ChatGPT.app's Codex or to a running agy TUI.
- Automatic model switching on quota exhaustion.
