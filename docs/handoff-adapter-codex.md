# Handoff — S5a adapter-codex (ADAPTER-CODEX)

**Branch:** `rust/adapter-codex`  
**Worktree:** `~/personal/pharos-wt/adapter-codex`  
**Exclusive dirs:** `rust/crates/adapter-codex/` (expanded; no split crate needed)  
**Contracts:** frozen `0.1.0` / `88f4c22` — **not edited**

## What was built

Expanded `pharos-codex-adapter` from a JSONL helper binary into a **lib + bin**:

- **`SessionAdapter`** trait + types (`session.rs`) — S2 consumption shape
- **`DeliveryWorker`** trait + `DeliveryDispatchResult` (`delivery.rs`) — maps vendor turns to `pharos_protocol::DeliveryState`
- **`CodexSessionAdapter`** over Codex App Server:
  - **stdio** transport (`codex app-server`) for isolated product path
  - **daemon proxy** WebSocket transport (preserved for `pharos-meshd` helper bin)
- Hard rule encoded: interrupt → `DeliveryState::Failed`, **never** `Completed`
- Live gated test: `tests/product_roundtrip.rs`

### PM follow-up fixes (2026-11-10)

- Failed `DeliveryDispatchResult` / assert paths now include real Codex turn status + vendor error (`TurnOutcome::failure_detail`).
- Test prints `dispatch.detail` + turns snapshot before asserting Completed.
- Idle settle before Queue turns uses `thread/read` **without** `includeTurns` (Codex 0.167 returns `list_turns is not supported yet` on empty threads when `includeTurns: true`).
- Live gate re-run **5/5 PASS** after the idle fix. No Failed→Completed coercion; no blind retries.

### Contract-bump proposal (BLOCKED-CONTRACT for promotion only)

Promote into Phase 0.x (`pharos-protocol` / `pharos-api`), do **not** invent forks:

1. `SessionAdapter` trait (+ `StartSessionRequest`, `PromptMode`, `TurnStatus`, `TurnOutcome`, `InterruptOutcome`)
2. `DeliveryWorker` trait (+ `DeliveryJob`, `DeliveryDispatchResult`)
3. Optional: `AdapterError` beside `PharosApiError`

Until then, S2 should depend on `pharos-codex-adapter::{SessionAdapter, DeliveryWorker}` (and sibling adapter crates mirroring the same traits).

## Gate commands + summary

```sh
cd rust
cargo fmt -p pharos-codex-adapter -- --check          # OK
cargo clippy -p pharos-codex-adapter --all-targets -- -D warnings  # OK
cargo test -p pharos-codex-adapter --lib --bins       # 5 passed
unset CODEX_HOME
# 5× series after idle fix:
for i in 1 2 3 4 5; do
  PHAROS_RUST_ADAPTER_CODEX_PRODUCT_PATH_TEST=1 \
    cargo test -p pharos-codex-adapter --test product_roundtrip -- --nocapture || break
done
# → SUMMARY pass=5 fail=0 (~9s/run); seed+DONE Completed; interrupt=Interrupted
```

## Evidence

- `internal/evidence/2026-11-10-rust-adapter-codex-product-roundtrip.md` (includes 5× table + pre-fix `list_turns` failure note)
- Live sidecar (msg-test): `~/personal/pharos-msg-test/peer-phase-a/rust-adapter-codex-1794339882268926000/product-roundtrip.txt`

## PARTIAL / NOT-TESTED

| Item | Mark | Reason |
|---|---|---|
| Original single PM `dispatch.state=Failed` root vendor error | PARTIAL | That run’s detail was not captured; post-fix 5× series did not reproduce; diagnostics now print detail on any future fail |
| Full Swift Host binder → Mesh `replyOnce` room persistence via Rust adapter | NOT-TESTED | Stream owns Rust adapter only; Swift Host binder path remains integration/captain + S2 |
| `pharos-meshd` builtin Codex delivery worker rewritten onto `DeliveryWorker` trait | NOT-TESTED | `main.rs` is captain-owned; bin JSONL bridge kept compatible |
| Daemon-proxy live product round-trip | NOT-TESTED | Product gate used stdio isolation (matches Swift product-path); daemon proxy covered by unit framing tests + existing Runtime path |
| HITL / approvalPolicy `on-request` through adapter | NOT-TESTED | Approvals defaulted to `never` for product path; S2 HITL owns approval wire-up |
| Steer mid-turn live | NOT-TESTED | API present (`PromptMode::Steer`); not exercised in this gate |
| Isolated `CODEX_HOME` without copying auth | NOT-TESTED | Empty home fails auth; live gate uses default `~/.codex` with CODEX_HOME unset |

## Wiring

See `docs/wiring-adapter-codex.md`. No workspace member append needed (crate already in `rust/Cargo.toml`). No `main.rs` edit.

STATUS: ADAPTER-CODEX-DONE
