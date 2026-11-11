# Wiring notes — S2 session-hitl

For merge captain only. This stream may append workspace members in a
`wiring-local` commit; captain reconciles `rust/Cargo.toml` and applies
`agent-runtime` `main.rs` hooks.

## Workspace members (appended locally)

```toml
"crates/pharos-session",
"crates/pharos-hitl",
"crates/pharos-goals",
```

Optional `[workspace.dependencies]`:

```toml
pharos-session = { path = "crates/pharos-session" }
pharos-hitl = { path = "crates/pharos-hitl" }
pharos-goals = { path = "crates/pharos-goals" }
```

## Reserved agent-runtime hooks (do **not** edit main.rs in this stream)

Files already present for captain to `mod`:

- `src/session_service.rs`
- `src/hitl_bridge.rs`

### `main.rs` include (captain only)

```rust
mod session_service;
mod hitl_bridge;
```

### Suggested registration (illustrative)

```rust
use pharos_codex_adapter::{CodexSessionAdapter, SessionAdapter};
use pharos_goals::open_goals_db;
use pharos_session::{AdapterSessionService, RecordingEventSink};
use std::sync::Arc;

fn build_session_service(data_dir: &std::path::Path) -> AdapterSessionService {
    let adapter: Box<dyn SessionAdapter> =
        Box::new(CodexSessionAdapter::connect_stdio().expect("codex"));
    let goals = open_goals_db(data_dir).expect("goals");
    AdapterSessionService::new(
        adapter,
        goals,
        Arc::new(RecordingEventSink::new()), // replace with S4 EventBus adapter
        "mac-air",
        "codex",
    )
}
```

HITL live approvals (deferred, human-proxy):

```rust
use pharos_hitl::{CodexHitlClient, HitlBridge, HitlDecision};

// CodexHitlClient::connect_stdio_hitl_home(isolated_codex_home)
// → poll_approval → publish_hitl_request → resolve(AllowedOnce|Denied)
```

## Trait for S4 (web stream)

```rust
use pharos_session::SessionService;
// Sync trait today; S4 wraps into async handlers (same pattern as S1 ThreadService).
// Events: pharos_api::ClientEvent (sessionGoalUpdated / approvalRequired / …).
```

## Env

| Var | Role |
|---|---|
| `PHAROS_RUST_SESSION_HITL_LIVE=1` | Gate live Codex approval + human-proxy round-trip |
| `AGENT_CLI_CREDENTIAL_STORE=file` | Already set by launcher on this host |
| `CODEX_HOME` | Unset for live gate; test creates isolated home under msg-test |
