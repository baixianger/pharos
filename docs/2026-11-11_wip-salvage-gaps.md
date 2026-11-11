---
summary: The WIP contains pre-migration features that need explicit Rust API and client ports; the Rust migration does not by itself establish feature parity.
---

# WIP salvage gaps — 2026-11-11

Compared `88f4c22..cbb7c8e` with `rust/wip-salvage`. Coverage below describes code found, not live verification. Historical validation documents describe the former Swift implementation.

| WIP feature | Rust coverage and remaining work |
| --- | --- |
| Host session query/action, remote session client, host identity and project paths (`HostSessionSchema`, `MeshHostSessionBridge`, `MeshRemoteHostSessionClient`, CLI agents) | **Missing end-to-end.** `rust/crates/pharos-protocol/src/lib.rs` names host session operations; `pharos-replica/src/handle.rs` dispatches runtime and replica operations, not host session query/action. Implement authorization, schemas, host routing and session actions, then connect HTTP/client surfaces. |
| Agy live session, history reader, streaming, thread relay and runtime bridge | **Partial.** `pharos-adapter-agy/src/agy.rs` implements ACP sessions, prompts, interrupts and in-memory turn history; `transport.rs` handles notifications, `delivery.rs` describes delivery. Existing-session discovery, durable native history replay, live client events and WIP thread reply correlation need ports and integration. No real host validation performed. |
| Codex live adapter, session configuration, approvals and thread relay | **Partial.** `adapter-codex` and `agent-runtime/src/main.rs` cover adapter calls and managed deliveries. Concrete fork IDs were ported here. WIP final-answer selection, persisted reply correlation and host-reply dispatch are missing; the WIP invokes the removed Swift mesh executable and needs a Rust delivery implementation. |
| Delivery candidate liveness, ambiguity rejection, idempotency validation and inspection (`agent-runtime` WIP) | **Missing or incomplete.** Current runtime has member submission, but not WIP candidate checks or inspection methods. Port these together with compatible host RPC and tests; blindly copying risks changing routing semantics. |
| DSH plugin automatic Mesh replies, liveness, duplicate and replacement handling | **Partial.** Plugin and Rust runtime exist. The WIP plugin depends on host-reply and the WIP runtime delivery contract; those are not ported. Socket environment alias was retained. Port and test the remaining behavior together against a Rust reply endpoint. |
| Swift Mesh broker, client, replica, delivery receipt states and distributed chat registry | **Partial.** `pharos-mesh`, `pharos-replica`, `pharos-thread` and `pharos-protocol` implement Rust primitives; WIP behavior and receipt semantics need contract-by-contract parity tests, especially ambiguous and uncertain deliveries. No Swift backend restored. |
| WebCanvas workspace, avatars, markdown and Swift shell/view models | **Ported with limits.** The app uses `WorkspaceWebView` with ClientKit; `pharos-web` serves the same workspace through HTTP/WS. The asset copies in `Sources/Pharos/Resources/WebCanvas/` and `webui/` must be changed together; `pharos-web/tests/asset_sync.rs` checks identical names and bytes. Browser and native use `transport.js`. The server binary currently uses fake services, not real sessions. Native app GUI interaction remains unverified. |
| ClientKit goal/todo progress, events, session metadata, configuration and approval changes | **Partial.** Progress reads, Rust goal/todo/approval events, session inventory metadata, project membership, thread reply references and request IDs are mapped. WIP configuration updates, attachment uploads, inventory diagnostics, questionnaire answers, cancellation choice and fetching the current approval snapshot do not have matching Rust endpoints/contracts. Unsupported mutations return errors; optional missing snapshots remain absent. |
| iOS mobile UI and Mesh TCP changes | **Unported.** Existing mobile client still uses its legacy Mesh TCP protocol and is outside the SwiftPM client-only build. Migrate transport and models to PharosClientKit / Rust HTTP/WS before carrying over the dependent changes and building the iOS target. |
| WIP tests and live probes | **Partial.** Fork ID, wire mapping, event mapping, transport errors and asset synchronization have regression checks. The browser workspace was exercised against local fake services. Most WIP tests target removed Swift modules or live hosts; translate their remaining assertions after feature ports. No real host probes were run. |
| WIP packaging, data-location, DESIGN and existing API/RFC edits | **Unported pending review.** WIP packaging and docs describe the old Swift Mesh system; reconcile individual useful details with current Rust packaging and contracts rather than replacing Phase E files wholesale. |

`pharos-web`'s fake service wiring and the daemon bridge placeholders are a material limitation independent of whether workspace assets are ported. No claim of live or cross-host feature parity is made here.

## Unavailable workspace operations

The HTTP router in `rust/crates/pharos-http/src/router.rs` exposes session list/history/send/steer/approval/progress, thread list/messages/reply, projects, inventory and events. It does **not** expose session command execution, session configuration reads/writes, attachment upload, current approval snapshot, questionnaire answers or cancelled approval decisions, thread-to-session binding, member detail/model/mode/avatar changes, stop/revive, remote project creation, or host checkout availability. Browser-only settings and avatar persistence also have no HTTP API. These operations are disabled where capability can be established or surface an unavailable error when requested; they are not reported as successful. The local macOS shell retains its native settings, local project-add and avatar preferences. A WebSocket disconnect is visible and requires page reload to reconnect.

`GET /api/v1/events` supplies future approval events, but there is no current-approval snapshot after page load or reconnection. The browser cannot recover an approval missed before subscription until the server exposes that snapshot. Rust provides compact assistant text history, not the WIP's complete live tool/reasoning block tree.

## Update 2026-11-11 — pending approval snapshot (`rust/hitl-persist`)

The statements above that “there is no current-approval snapshot after page load or reconnection” and that a WebSocket disconnect “requires page reload to reconnect” are superseded for pending HITL approvals by branch `rust/hitl-persist`:

- Pending approvals are persisted by `pharos-hitl` (`PendingApprovalStore`: versioned JSON under the Host data dir, atomic temp+fsync+rename writes, corrupt/empty file is an error, 45m expiry, prune, idempotent first-wins decisions).
- `GET /api/v1/approvals?state=pending[&sessionId=]` exposes the durable snapshot; `POST /api/v1/sessions/{id}/approval` persists the decision (200 with `alreadyResolved`, 404 `approvalNotFound`, 400 session mismatch, 409 expired) and reverts the durable decision if downstream session/adapter dispatch fails so it stays retryable.
- `webui/transport.js` and `Sources/Pharos/Resources/WebCanvas/transport.js` (byte-identical copies) fetch that snapshot on page load and on every WebSocket `open`, dedupe live events by `approvalId`, and reconnect with backoff instead of requiring a reload.
- Not done: Swift ClientKit “current approval snapshot” request/models (no macOS verification on Linux); real adapter/session wiring (the `pharos-web` binary still uses fake S1/S2 services).

## Update 2026-11-11 — web workspace endpoints (`rust/web-endpoints`)

The "Unavailable workspace operations" statements above are superseded for the
following operations by branch `rust/web-endpoints` (see
`docs/2026-11-11_web-endpoints-api.md` for the contract). All routes are inside
`api_router`/`app_router_with_token` (bearer auth) and are listed in the
OpenAPI output; stores are versioned, atomically-written files under the Host
`--data-dir`, and a corrupt store is a hard startup error (never a silent
reset):

- **Thread ↔ session binding**: `GET/PUT/DELETE /api/v1/threads/{id}/bindings[/{member}]`,
  `GET /api/v1/threads/{id}/members` (replica members ∪ bound members with
  durable settings). The binding is the read surface delivery routing can
  consume; agent-runtime delivery logic is unchanged.
- **Session configuration**: `GET/PATCH /api/v1/sessions/{id}/config`
  (model/mode, supported fields + honest capability flags). Adapters that
  cannot apply a field return `502 unsupportedField` with the field id — never a
  fake save. The current Codex adapter exposes no writable configuration, so
  real live sessions report an empty view / explicit unsupported write.
- **Extended approval decisions**: the existing
  `POST /api/v1/sessions/{id}/approval` body is now a superset of the frozen
  one: `decision: "cancelled"` and `questionnaireAnswers`. Persistence reuses
  `pharos-hitl`'s `PendingApprovalStore` (first-wins idempotency, 45m expiry,
  revert-on-failed-dispatch), extended with the `StoredDecision` model.
- **Member settings / avatars**: `GET/PATCH /api/v1/members/{id}`,
  `GET/PUT/DELETE /api/v1/members/{id}/avatar` (png/jpeg, ≤512 KiB, stored in
  the data dir, survives restart).
- **Attachment upload**: `POST /api/v1/sessions/{id}/attachments` (base64 JSON,
  allowlisted content types, ≤10 MiB), metadata/content/list reads, and
  `attachmentIds` references on `POST /sessions/{id}/messages`. Adapters that
  cannot consume attachments answer `502 unsupportedField` — the message is not
  reported as sent.
- **stop/revive**: `POST /api/v1/sessions/{id}/stop|revive`; no adapter
  currently advertises these, so the real backend answers explicit
  `502 unsupportedOperation` while the fake test service exercises the success
  path.
- **Front end**: `webui/` and `Sources/Pharos/Resources/WebCanvas/` (byte
  identical, `asset_sync` green) now load/refresh these surfaces and dispatch
  the writes; previously "unavailable" buttons call the new routes, and
  capability-gated controls stay disabled when the server reports no support.
  Session **command** execution and project creation remain unavailable (no
  endpoint; UI still says so honestly).

Not done: real vendor end-to-end (the live Codex adapter still exposes no
config/attachment/stop capabilities, so those paths are honest 502s there);
Swift ClientKit models for the new endpoints (Linux box: Swift not compiled).
