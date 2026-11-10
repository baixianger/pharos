---
summary: RFC-007 Phase 0 shared contract freeze (CONTRACTS_VERSION=0.1.0).
tag: rust-contracts-0.1.0
---

# RFC-007 Contracts (Phase 0)

**CONTRACTS_VERSION = `0.1.0`**  
**Local git tag = `rust-contracts-0.1.0`**  
**STATUS gate = `RUST-P0-DONE`**

These crates are the only shared surface parallel streams may depend on for
cross-stream types. Streams must not edit each other’s exclusive directories; if
a type is missing, bump contracts via Phase 0.x (merge captain) instead of
forking shapes.

## Crates

| Crate | Path | Role |
|---|---|---|
| `pharos-protocol` | `rust/crates/pharos-protocol` | Delivery/session enums, replica RPC op IDs, Runtime method names, grokbot/webhook ID-only wake, adapter kinds, wire event IDs |
| `pharos-store-schema` | `rust/crates/pharos-store-schema` | `SCHEMA_VERSION=1`, path conventions, table names, Phase 0 SQL DDL (`PHASE0_DDL`) |
| `pharos-api` | `rust/crates/pharos-api` | `/api/v1` routes, `PharosApiError`, Session/Thread/Project/HITL/Goal DTOs, `ClientEvent`, OpenAPI stub |

**Allowed dependency graph**

```text
pharos-api ──► pharos-protocol
pharos-store-schema  (standalone)
pharos-protocol      (standalone)
```

None of these crates may depend on `adapter-*`, CLI, HTTP server, mesh/iroh
implementations, or Swift.

Workspace members are listed in `rust/Cargo.toml` (merge captain). Existing
`agent-core` / `adapter-codex` / `agent-runtime` are unchanged in behavior for
Phase 0.

## Coverage by stream

| Stream | Consumes from contracts |
|---|---|
| **S1** CLI/Thread/grokbot | `pharos-api` thread DTOs + reply request; `pharos-protocol` `DeliveryState`, `grokbot::*`, `ThreadMentionWake`; store tables `rooms`/`memberships`/`messages`/`deliveries` |
| **S2** Session/HITL/Goal | session/approval/progress DTOs + `ClientEvent` approval/goal variants; tables `session_*` / `approvals` |
| **S3** mesh/iroh | `ReplicaRpcOperation`, wire events; tables `trust_groups` / `device_identity` / replica message tables; path `mesh/replica.sqlite3` |
| **S4** web/API/UI | `routes::*`, `openapi_stub_json()`, `HealthResponse`, WS `ClientEvent`; serves `paths::WEBUI_DIR` |
| **S5a–d** adapters | `AdapterKind`, `AdapterManifest`, Runtime method names, `DeliveryState` |
| **S6** Swift client | JSON shapes in `pharos-api` (mirror in ClientKit); errors; events WS |

## Acceptance (Phase 0)

```sh
source "$HOME/.cargo/env"
cd rust
cargo check -p pharos-api -p pharos-protocol -p pharos-store-schema
cargo test  -p pharos-api -p pharos-protocol -p pharos-store-schema
```

- Three crates compile with no adapter/CLI/web deps.
- `CONTRACTS_VERSION` constants equal `0.1.0` in all three libs.
- Local tag `rust-contracts-0.1.0` points at the Phase 0 commit.

## Change control

1. Propose DTO/SQL changes in a contracts-only PR/branch.
2. Bump `CONTRACTS_VERSION` (and crate `version`) + `SCHEMA_VERSION` when DDL breaks.
3. Retag `rust-contracts-0.x.y` after merge captain lands.
4. All open stream worktrees rebase onto the new tag before continuing.

## Non-goals (Phase 0)

No CLI binary, no HTTP server, no iroh/mesh implementation, no vendor adapters,
no Swift ClientKit rewrite, no deletion of Swift backend modules.
