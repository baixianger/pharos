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
PHAROS_RUST_ADAPTER_CODEX_PRODUCT_PATH_TEST=1 \
  cargo test -p pharos-codex-adapter --test product_roundtrip -- --nocapture
# → ok in ~8s; Codex 0.167 seed+DONE completed; interrupt=Interrupted; delivery Failed on interrupt
```

## Evidence

- `internal/evidence/2026-11-10-rust-adapter-codex-product-roundtrip.md`
- Live sidecar (msg-test): `~/personal/pharos-msg-test/peer-phase-a/rust-adapter-codex-1794335822/product-roundtrip.txt`

## PARTIAL / NOT-TESTED

| Item | Mark | Reason |
|---|---|---|
| Full Swift Host binder → Mesh `replyOnce` room persistence via Rust adapter | NOT-TESTED | Stream owns Rust adapter only; Swift Host binder path remains integration/captain + S2 |
| `pharos-meshd` builtin Codex delivery worker rewritten onto `DeliveryWorker` trait | NOT-TESTED | `main.rs` is captain-owned; bin JSONL bridge kept compatible |
| Daemon-proxy live product round-trip | NOT-TESTED | Product gate used stdio isolation (matches Swift product-path); daemon proxy covered by unit framing tests + existing Runtime path |
| HITL / approvalPolicy `on-request` through adapter | NOT-TESTED | Approvals defaulted to `never` for product path; S2 HITL owns approval wire-up |
| Steer mid-turn live | NOT-TESTED | API present (`PromptMode::Steer`); not exercised in this gate |
| Isolated `CODEX_HOME` without copying auth | NOT-TESTED | Empty home fails auth; live gate uses default `~/.codex` with CODEX_HOME unset |

## Wiring

See `docs/wiring-adapter-codex.md`. No workspace member append needed (crate already in `rust/Cargo.toml`). No `main.rs` edit.

STATUS: ADAPTER-CODEX-DONE
