---
summary: Converge all Pharos backends into one Rust service; Swift keeps only Apple clients (SwiftUI + WebKit). Inventory + staged migration plan only — no code move in this RFC.
status: draft-for-review
date: 2026-11-10
supersedes_partially: RFC-004 (Runtime-only Rust); complements RFC-005/006
---

# RFC-007: Unified Rust Backend (inventory & plan)

**STATUS: RUST-PLAN-DONE** (planning only; migration not started)

## 0. Decision (user architecture, 2026-11-10 18:01)

All backend responsibility converges into **one independent Rust backend
process**. Swift remains **Apple clients only** (SwiftUI shell + WebKit hosting
the built-in Web UI). Other frontends may use any stack; they talk only to this
backend’s HTTP/WS API.

The Rust backend owns:

| Domain | Today (mostly Swift) | Target (Rust) |
|---|---|---|
| Mesh / network / sync | `PharosMesh*`, MeshKit/Iroh bridge | Rust mesh + native iroh |
| Agent Runtime | `pharos-meshd` (Rust) + Swift bridges | expand existing `pharos-meshd` |
| Session / Thread | `PharosRuntime` + Mesh replica chat | Rust session + thread services |
| HITL / Goal / Todo | adapters + human-proxy | Rust adapters + webhook/HITL |
| CLI | Swift `pharos-mesh` | Rust CLI (same UX, replaces Swift binary) |
| Web UI + API | WebCanvas bundle in app + WK bridge | Rust serves static Web UI + HTTP/WS API |

**This document is inventory + plan only. Do not start migration until review.**

Safety bounds (unchanged): real traffic only in `pharos-msg-test`; never touch
mac-pro / 3080 Host `ipc.sock` / company identity; no push/force from agents.

---

## 1. Target architecture

```text
┌──────────────────────────────────────────────────────────────────┐
│  Frontends (any tech)                                            │
│  ┌─────────────────────┐  ┌──────────────┐  ┌─────────────────┐ │
│  │ macOS Pharos.app    │  │ iOS (later)  │  │ Web / other     │ │
│  │ SwiftUI chrome +    │  │ WKWebView    │  │ browser / CLI   │ │
│  │ WKWebView → API     │  │ → API        │  │ → API           │ │
│  └─────────┬───────────┘  └──────┬───────┘  └────────┬────────┘ │
└────────────┼─────────────────────┼───────────────────┼──────────┘
             │ HTTP + WebSocket (canonical PharosClient API)       │
             ▼                     ▼                   ▼
┌──────────────────────────────────────────────────────────────────┐
│  Rust backend process  (working name: pharosd / expanded         │
│                        pharos-meshd)                             │
│  ┌──────────────┐ ┌─────────────┐ ┌──────────┐ ┌──────────────┐ │
│  │ HTTP/WS API  │ │ Static Web  │ │ CLI bin  │ │ human-proxy  │ │
│  │ (CLIENT-API) │ │ UI assets   │ │ pharos-* │ │ / webhooks   │ │
│  └──────┬───────┘ └─────────────┘ └────┬─────┘ └──────┬───────┘ │
│         │                              │              │         │
│  ┌──────▼──────────────────────────────▼──────────────▼───────┐ │
│  │ Session · Thread · HITL · Goal/Todo · Delivery/Runtime     │ │
│  └──────────────────────────┬─────────────────────────────────┘ │
│  ┌──────────────────────────▼─────────────────────────────────┐ │
│  │ Mesh / sync / identity / attachments (iroh-native)         │ │
│  └──────────────────────────┬─────────────────────────────────┘ │
│                             │ vendor surfaces                     │
│           Codex · Agy ACP · DSH plugin/web · grokbot webhook      │
└──────────────────────────────────────────────────────────────────┘
```

Invariants:

1. **One Host authority** per machine: the Rust process owns Runtime registry,
   delivery queues, session adapters, and mesh replica for that Host.
2. **Clients are skins**: no process spawn, no mesh routing, no durable agent
   state in SwiftUI (aligns with RFC-006 Invariant 1; today’s
   `DesktopPharosClientService` violates this and must thin out).
3. **Web UI is backend-served**: the same static assets WebKit loads today move
   under the Rust HTTP server; WebKit stops using `webkit.messageHandlers`
   for product APIs and uses HTTP/WS instead (bridge may remain briefly as a
   compatibility shim during cutover).
4. **CLI is backend-local**: `pharos-mesh …` becomes a Rust binary talking to
   the local daemon (UDS or localhost), not a SwiftPM executable linking MeshCore.

Relation to RFC-004: RFC-004 moved Codex transport + Runtime registry into
`pharos-meshd`. RFC-007 **widens** that process into the full backend, rather
than leaving Mesh/Thread/CLI/Web in Swift forever.

---

## 2. Inventory — Swift modules (`Sources/`)

Counts are `*.swift` LOC as of 2026-11-10 (approx). **Move** = belongs in Rust
backend. **Stay** = Apple client. **Split** = extract API surface / thin client.

| Module | Files | LOC | Depends on | Role today | Disposition |
|---|---:|---:|---|---|---|
| `CSQLite` | shim | — | system sqlite3 | C module map for replica | **Move** with replica (or replace with `rusqlite`) |
| `PharosMeshProtocol` | 14 | 3 295 | none | Wire schemas: trust, replica RPC, host session/command, sync, legacy mesh | **Move** (schemas → Rust types / JSON schema; keep mirrored DTOs in ClientKit if needed) |
| `PharosMeshIdentity` | 5 | 1 480 | Protocol, swift-crypto | Device identity, trust pairing, keychain/file storage, membership transitions | **Move** (Keychain → OS keystore via Rust + macOS helper only if required) |
| `PharosMeshIroh` | 1 | 542 | Protocol, **MeshKit / MeshKitIroh** | Thin Swift wrapper over MeshKit’s iroh endpoint/QUIC | **Move** → **native iroh** in Rust (drop MeshKit Swift dependency from backend) |
| `PharosMeshReplica` | 9 | 6 933 | Protocol, Identity, CSQLite | SQLite replica store (~4k LOC), chat registry, replica RPC, attachments | **Move** (hardest persistence piece) |
| `PharosMeshControl` | 1 | 258 | Protocol, Identity, Iroh, Replica | Distributed host controller | **Move** |
| `PharosMeshLifecycle` | 1 | 645 | Protocol, Identity, Iroh, Replica | Trust-group lifecycle | **Move** |
| `PharosMeshCore` | 30 | 13 890 | all Mesh*, CSQLite, Crypto | Broker, LightRelay/Commands, DistributedAgentChat, local service, launch agent, migration | **Move** |
| `PharosAgentCore` | 2 | 306 | none | Shared Runtime contracts (delivery states, surfaces) | **Move** / already partially mirrored in `rust/crates/agent-core` |
| `PharosCodexAdapter` | 2 | 355 | AgentCore | Thin Swift Codex App Server driver over Rust helper | **Delete after** Rust owns Codex end-to-end (adapter-codex already exists) |
| `PharosRuntime` | 64 | 18 600 | MeshCore, AgentCore, ClientKit | Adapters (Agy/DSH/Codex), CLIAgents, Host session/thread bridges, delivery, human-proxy, grokbot, inventory, SSH | **Move** (largest operational surface) |
| `PharosMesh` (exe `pharos-mesh`) | 5 | 3 799 | Mesh*, Runtime, AgentCore, ClientKit, CodexAdapter | Headless CLI + node install/serve | **Replace** with Rust CLI |
| `PharosClientKit` | 11 | 1 504 | Foundation only (intended) | Canonical DTOs + `PharosClientService` protocol | **Stay** as Swift client SDK; eventually HTTP/WS implementation of the protocol (models may be generated from shared OpenAPI/JSON Schema) |
| `Pharos` (app) | 76 | 24 102 | ClientKit, MeshCore, Runtime, Lifecycle, Sparkle | SwiftUI shell, WebKit, Desktop service, ProjectStore, Settings, DistributedMeshSupport, app CLI | **Split**: keep UI/WebKit/Sparkle/Settings chrome; **move** mesh/runtime orchestration out of process |

### 2.1 `PharosRuntime` breakdown (where the work is)

| Area | ~LOC | Notes |
|---|---:|---|
| Root Runtime (registry client/server facades, light session, webhooks, …) | ~7.4k | Overlaps Rust `pharos-meshd` registry; Swift still owns much policy |
| `CLIAgents/` | ~5.9k | Inventory, SSH, Codex daemon client, project paths, lifecycle |
| `Adapters/Dsh/` | ~2.2k | Web Host HTTP/WS, live session, thread bridge |
| `Adapters/Agy/` | ~1.2k | ACP, transcript, thread relay/bridge |
| `Adapters/Codex/` | ~0.7k | Backend adapter + stdio/remote transport |
| `Adapters/Translators/` | ~0.7k | Canonical mapping |
| Thread/session bridges + grokbot + human-proxy | (in root) | Product delivery honesty; already proven E2E |

### 2.2 `Pharos` app — stay vs leave

**Stay (client):**

- SwiftUI shell (`PharosMainShellView`, navigation, composer chrome, design tokens)
- WebKit hosts (`PharosWebCanvasView`, `WorkspaceWebView`) — load backend-served UI
- Avatars, settings presentation, Sparkle updater, bundle resources packaging
- Thin `PharosClientService` HTTP/WS client (replace `DesktopPharosClientService` guts)

**Leave / move:**

- `DistributedMeshSupport.swift`, `DesktopPharosClientService` backend paths
- In-process Mesh/Runtime startup, LaunchAgent logic that belongs beside daemon
- `MeshHooks`, heavy `PharosCore` agent process control
- WebCanvas **product logic** stays as web assets but is **served by Rust**; JS should call HTTP/WS, not only `webkit.messageHandlers.pharosBridge`

### 2.3 Web UI today

`Sources/Pharos/Resources/WebCanvas/` ≈ 2.6k LOC (js/css/html) + vendored
markdown-it. Bridge is currently:

```js
window.webkit?.messageHandlers.pharosBridge?.postMessage({ action, payload })
```

Target: same UI bundle embedded/served by Rust (`GET /` + assets); API via
`/api/...` + `/ws`; WebKit is a browser surface.

### 2.4 iOS

`ios/PharosMobile/` (~30 Swift files) already speaks mesh wire over TCP — treat
as **another client** of the Rust API after macOS cutover (out of scope for early
phases; do not block Linux box goal).

---

## 3. Inventory — Rust (`rust/`)

Workspace (`rust/Cargo.toml`, edition 2024, rust-version 1.95):

| Crate | Binary / lib | LOC | Role today | Gap vs RFC-007 |
|---|---|---:|---|---|
| `pharos-agent-core` | lib | 65 | Sidecar IPC / shared contracts stub | Expand to full CLIENT-API + Runtime schema |
| `pharos-codex-adapter` | bin helper | 284 | Codex daemon resolve, WS upgrade, App Server JSON-RPC | Keep; become library used by runtime |
| `pharos-agent-runtime` (`pharos-meshd`) | bin | 2 040 | Registry, delivery queue, Unix JSON-RPC, launch requests, Codex worker path | **Seed process** to grow into full backend |

**Not present yet (needed):**

- HTTP server + OpenAPI/WS gateway
- Static Web UI embedding
- CLI crate replacing Swift `pharos-mesh`
- Thread/chat replica (SQLite or equivalent)
- Mesh sync + **native iroh** endpoint
- Agy / DSH / grokbot adapters in Rust
- HITL human-proxy + webhook (port from `HumanProxyChannel`)

### 3.1 iroh usage today

- Swift does **not** call iroh crates directly.
- `PharosMeshIroh` delegates to **MeshKit / MeshKitIroh** (`github.com/baixianger/MeshKit`, pinned `0.2.1`), which wraps iroh endpoint bind, tickets, relay policy, request/response over QUIC.
- Backend migration should use **iroh Rust crates natively** inside the daemon (same protocols/tickets if possible) and retire MeshKit from the backend path. MeshKit may remain relevant only if other Swift clients briefly need it — prefer not.

---

## 4. API boundary

Source of truth for client semantics: [`docs/CLIENT-API.md`](CLIENT-API.md) +
`PharosClientService` in `PharosClientKit`.

Proposed transport (Rust-owned):

| Surface | Purpose |
|---|---|
| `POST/GET /api/v1/...` | Sessions, threads, projects, approvals, goals/todos, inventory |
| `WS /api/v1/events` | Canonical streaming deltas, presence, delivery receipts |
| `UDS` JSON-RPC (existing) | Local high-privilege Runtime / delivery (keep for adapters & CLI) |
| Static `/` + `/assets/*` | Web UI currently under `WebCanvas/` |
| CLI → UDS/HTTP | `pharos thread read|reply`, `pharos session …`, `pharos mesh …` |

Rules:

- Payload shapes stay canonical (Session rich model vs Thread plain bubbles).
- Webhook HITL / grokbot wake payloads remain **ID-only** (no message bodies/secrets).
- Peer Host Runtime allowlist (`delivery.submit-member`, etc.) stays explicit.

`PharosClientKit` becomes a Swift HTTP/WS client of this API; macOS app depends
on ClientKit + Apple UI only.

---

## 5. Data / state storage migration

| Store | Location today | Target |
|---|---|---|
| Mesh replica SQLite | Mesh data-dir via `DistributedMeshStore` | Rust-owned SQLite (schema migration or dual-read window) |
| Runtime registry | `pharos-meshd` JSON under Runtime data-dir | Keep/evolve in Rust (already) |
| Trust / device identity | files + Keychain (`PharosMeshIdentity`) | Rust file store + platform secret helper |
| Project registry | `~/Library/Application Support/Pharos/projects.json` | Prefer daemon-owned projects API; app may cache |
| Human-proxy requests | `~/personal/pharos-msg-test/human-requests/` (tests) + webhook env | Same paths; logic in Rust |
| Vendor state | Codex/Agy/DSH own stores | Unchanged; adapters only |
| Web UI | App bundle Resources | Daemon static dir / embed |

Migration principle: **per-Host cutover** with feature flags; never rewrite
vendor session DBs; msg-test isolated data-dirs first.

---

## 6. Migration phases (suggested order)

Do **not** delete Swift backend modules until the phase’s acceptance tests pass
on msg-test (and Linux box where noted).

### Phase A — Skeleton & CLI/Thread slice *(start here)*

**Ship:** expand `pharos-meshd` (or `pharosd`) with:

- HTTP health + minimal `/api/v1/threads/{id}/messages`
- Rust CLI: `thread read`, `thread reply --as grokbot` (parity with today’s Swift CLI)
- grokbot webhook member bridge in Rust (port `GrokbotThreadBridge` + `HumanProxyChannel`)
- Serve a stub or copied Web UI static root (even if feature-incomplete)

**Still Swift:** Mesh replica source of truth may be called via temporary FFI/UDS
bridge *or* Rust reads the same SQLite with a compatibility layer — pick one in
phase kickoff (Open Question Q1).

**Accept:**

- Re-run `GrokbotMemberLiveTests` / manual CLI against Rust CLI + daemon
- Unit: webhook success = `injected`, replyOnce = `completed`, 45m = `failed`

### Phase B — Session + HITL + Goal/Todo

**Ship:** Codex/Agy/DSH session adapters behind Rust Runtime; approvals;
human-proxy resolve; Goal/Todo read/write where already proven.

**Accept (reuse E2E):**

- Peer HITL webhook+45m (`STATUS: peer-hitl done` evidence path)
- Isolated DSH product round-trip
- Isolated Codex app-server product round-trip
- Host Session progress/approval events via WS API

### Phase C — Mesh / sync / Peer Runtime

**Ship:** native iroh transport; replica sync; Peer `host.runtime.call.v1`;
replace Swift MeshCore broker paths for product mode.

**Accept:**

- XHOST mini↔air Peer submit + replyOnce
- box Linux headless Runtime (already partially proven) **plus** Thread/CLI on box
- Trust pairing / membership smoke on msg-test only

### Phase D — Web UI cutover + thin Swift app

**Ship:** WebCanvas assets served by Rust; WebKit loads `http://127.0.0.1:<port>/`;
remove `pharosBridge` product calls; `DesktopPharosClientService` → HTTP ClientKit.

**Accept:**

- Desktop smoke: open Thread + Session against msg-test daemon
- ArchitectureBoundaryTests: app target does not link MeshCore/Runtime

### Phase E — Delete Swift backend modules

Remove or quarantine: `PharosMesh*`, `PharosRuntime`, `PharosMesh` exe,
`PharosCodexAdapter`, `CSQLite` (if unused), app-side mesh support files.

**Accept:** `swift build` client-only package; Linux CI builds Rust backend only;
full regression of A–D gates.

### Linux box goal

End state: `ssh box@grok-bot` runs the **same** Rust backend binary as macOS
Hosts (mesh + Runtime + API + CLI + optional headless Web UI), without Swift.
Phases A–C are the critical path for box; D is macOS-client-specific.

---

## 7. Acceptance test map (reuse existing E2E)

| Gate | Existing evidence / test | Phase |
|---|---|---|
| Grokbot member | `GrokbotMemberLiveTests`, `GB-THD-01…05`, summary 2026-11-10 | A |
| Thread CLI read/reply | `docs/agents/grokbot/threads/2026-11-10_protocol.md` | A |
| Peer HITL | webhook + 45m HITL evidence | B |
| DSH product round-trip | `PHAROS_HOST_THREAD_DSH_PRODUCT_PATH_TEST` | B |
| Codex product round-trip | `PHAROS_HOST_THREAD_CODEX_PRODUCT_PATH_TEST` | B |
| XHOST mini↔air | Peer `delivery.submit-member` + replyOnce | C |
| box headless Runtime | xhost-box meshd evidence; extend to Thread/CLI | C |
| Client thinness | ArchitectureBoundary + no MeshCore link | D–E |

All live tests remain gated and confined to `pharos-msg-test`.

---

## 8. BACKEND-MATRIX annotation

Capability **Status** cells are **unchanged**. Rows owned by Swift backend
modules today are annotated **`planned-rust`** in
[`BACKEND-MATRIX.md`](BACKEND-MATRIX.md) (section banners). Status flips only
when Rust cutover evidence lands.

---

## 9. Risks

1. **Replica fidelity** — `DistributedMeshStore` (~4k LOC) + sync schemas are
   the highest rewrite risk; dual-running Swift/Rust replicas can diverge.
2. **iroh / MeshKit parity** — ticket formats, relay policy, and admission must
   interoperate with any peer still on MeshKit during mixed fleets.
3. **Keychain & LaunchAgent** — macOS secrets and GUI-independent lifecycle need
   an explicit daemon install story (RFC-004 Phase 3 unfinished).
4. **Adapter surface area** — DSH (HTTP/WS + plugin) and Agy (ACP + transcripts)
   dwarf Codex’s already-ported path; underestimating ports will stall Phase B.
5. **WebKit bridge freeze** — product JS still posts to `pharosBridge`; cutover
   needs a compatibility window or flag day.
6. **CLI userspace** — agents/scripts depend on Swift `pharos-mesh` flags;
   Rust CLI must keep grokbot/thread/human-proxy UX stable.
7. **Mixed Host versions** — mini/air/box on different binaries during C will
   break XHOST unless protocol versions negotiate.
8. **Scope creep into vendor internals** — must not touch Codex `ipc.sock` /
   ChatGPT.app private pipes / company Hosts (existing hard rules).

---

## 10. Open questions (need owner decisions)

| ID | Question | Default if unspecified |
|---|---|---|
| Q1 | Phase A Thread storage: reimplement SQLite in Rust now, or temporary UDS call into Swift replica? | Prefer Rust SQLite compatibility reader ASAP; avoid long-lived Swift dependency |
| Q2 | Final daemon name: keep `pharos-meshd` or rename `pharosd`? | Keep `pharos-meshd` until Phase E |
| Q3 | Single process vs Runtime + Mesh sidecars? | **Single process** (user decision); optional internal threads |
| Q4 | Shared schema IDL (OpenAPI / JSON Schema / Prost)? | OpenAPI for HTTP + JSON Schema for events |
| Q5 | Identity on Linux box without Keychain? | File-backed keys with 0600 under data-dir |
| Q6 | Do iOS/TCP clients wait for HTTP API or keep legacy mesh wire temporarily? | Legacy wire until Phase C complete; then API |
| Q7 | Web UI build pipeline (raw static vs bundled npm)? | Keep raw static WebCanvas move-first; toolchain later |
| Q8 | Who owns ProjectStore — daemon or macOS app preferences? | Daemon API; app caches |

---

## 11. Explicit non-goals (this planning round)

- No code moves, no module deletions, no API renames in tree beyond docs/matrix.
- No push / force / production Host changes.
- No claim that RFC-004 Phase 3 is finished — this RFC subsumes the remaining
  “Swift Runtime Host removal” work into Phases B–E.

---

## 12. Stop point

**STATUS: RUST-PLAN-DONE**

Await review of architecture, phase order, Q1–Q8, and risks before any
migration commit.
