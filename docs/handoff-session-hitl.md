# Handoff — S2 session-hitl (SESSION-HITL)

**Branch:** `rust/session-hitl`  
**Worktree:** `~/personal/pharos-wt/session-hitl`  
**Exclusive dirs:** `rust/crates/pharos-session/`, `rust/crates/pharos-hitl/`, `rust/crates/pharos-goals/`; `agent-runtime` stubs `src/session_*.rs`, `src/hitl_*.rs`  
**Contracts:** frozen `0.1.0` — **not edited**

## What shipped

1. **`pharos-hitl`**
   - Human-proxy channel (request markdown, `.done.md`, ID-only `hitl-request` webhook)
   - `HitlBridge` honest states: webhook 2xx → `Injected`; resolve → `AllowedOnce` / `Denied`; 45m → `Failed`
   - `CodexHitlClient`: deferred-approval stdio client + local `codex-code-mode-host` (Codex 0.167)
   - Live gated test: `tests/codex_hitl_live.rs` (`PHAROS_RUST_SESSION_HITL_LIVE=1`)

2. **`pharos-session`**
   - `SessionService` + `AdapterSessionService` over `Mutex<Box<dyn SessionAdapter>>` (Codex adapter trait)
   - Emits `pharos_api::ClientEvent` progress/approval shapes (JSON snapshot tests for S4 WS-bridge)
   - Hard rule: interrupt/failed never mapped to Completed

3. **`pharos-goals`**
   - SQLite Goal/Todo R/W on `PHASE0_DDL` (`session_goals` / `session_todos`)
   - Msg-test smoke: `tests/msg_test_smoke.rs`

4. Docs: `docs/wiring-session-hitl.md` (captain hooks; no `main.rs` edit)

## Gate commands

```sh
cd rust
cargo fmt -p pharos-session -p pharos-hitl -p pharos-goals -- --check
cargo clippy -p pharos-session -p pharos-hitl -p pharos-goals --all-targets -- -D warnings
cargo test -p pharos-session -p pharos-hitl -p pharos-goals

unset CODEX_HOME
export AGENT_CLI_CREDENTIAL_STORE=file
for i in 1 2 3; do
  PHAROS_RUST_SESSION_HITL_LIVE=1 \
    cargo test -p pharos-hitl --test codex_hitl_live -- --nocapture || break
done
# → SUMMARY pass=3 fail=0 (~11–13s/run)
```

## Evidence

- `internal/evidence/2026-11-10-rust-session-hitl-gates.md`
- `internal/evidence/2026-11-10-rust-session-hitl-live-run1.log`
- `internal/evidence/2026-11-10-rust-session-hitl-live-run2.log`
- `internal/evidence/2026-11-10-rust-session-hitl-live-run3.log`

## PASS / PARTIAL / NOT-TESTED

| Item | Mark | Reason |
|---|---|---|
| HITL unit: webhook → injected | PASS | `webhook_success_is_injected` |
| HITL unit: resolve allowedOnce / denied | PASS | `resolve_allowed_once_and_denied` |
| HITL unit: 45m → failed | PASS | fake-clock timeout branch (no wall-clock 45m) |
| Live Codex approval + human-proxy path ×3 | PASS | Injected→allowedOnce→turn completed; self-resolved `.done.md` after webhook |
| Session progress/approval `ClientEvent` JSON shapes | PASS | snapshot test matching `pharos-api` camelCase tags |
| `dyn SessionAdapter` consumption | PASS | `AdapterSessionService` + FakeAdapter unit; Codex trait from `pharos-codex-adapter` |
| Goal/Todo R/W on isolated msg-test data dir | PASS | `msg_test_smoke` |
| External human SSH / wall-clock 45m operator wait | PARTIAL | Live self-resolves after inject (S1 grokbot parity); timeout path unit-only |
| Live approval via S5a `CodexSessionAdapter` stdio | PARTIAL | Adapter stdio **auto-accepts** approvals + hardcodes `approvalPolicy=never`; live uses `CodexHitlClient` deferred path |
| `pharos-meshd` main.rs registration | NOT-TESTED | Captain-owned; stubs + wiring snippets only |
| Peer mini→air Host RPC HITL (Swift E2E) | NOT-TESTED | Local air Codex round-trip only (this stream host) |
| Interrupt → never Completed on live Codex via session service | NOT-TESTED | Mapped in unit/FakeAdapter path; live gate focused on approval |

## Interface issues (do **not** move traits here)

Keep consuming `pharos_codex_adapter::{SessionAdapter, DeliveryWorker}` until Phase 0.x.

Proposed Phase 0.x / S5a follow-ups (BLOCKED for promotion only):

1. Honor `StartSessionRequest.mode` → `approvalPolicy` (`yolo`→never, else on-request) — today always `never`.
2. Stdio transport: add defer-approval mode (queue `item/*/requestApproval` instead of auto-`accept`).
3. Extend `SessionAdapter` with `poll_approvals` / `resolve_approval` (or promote HITL client API into contract).
4. Optional: promote `SessionAdapter` / `DeliveryWorker` into `pharos-protocol` / `pharos-api` (S5a already proposed).

## Wiring

See `docs/wiring-session-hitl.md`. Local `wiring-local` commit appends the three crates to `rust/Cargo.toml`. No `main.rs` edit.

STATUS: SESSION-HITL-DONE
