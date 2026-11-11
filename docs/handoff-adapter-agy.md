# Handoff — S5c adapter-agy (ADAPTER-AGY)

**Branch:** `rust/adapter-agy`  
**Worktree:** `~/personal/pharos-wt/adapter-agy`  
**Exclusive dirs:** `rust/crates/pharos-adapter-agy/`  
**Contracts:** frozen `0.1.0` — **not edited**

## What was built

New crate `pharos-adapter-agy` implementing the S5a adapter surface over
Antigravity CLI ACP (`agy acp --stdio`, observed 1.5.5 on this Host):

- **Mirrored** `SessionAdapter` + `DeliveryWorker` traits (+ types) from
  `pharos-codex-adapter` (S5a). Not moved into contracts — see interface issue
  below.
- **`AgySessionAdapter`**:
  - Spawns long-running `agy acp --stdio` with background stdout reader
  - `session/new` → start; `session/prompt` (non-blocking start + `wait_turn`)
  - Captures `session/update` `agent_message_chunk` text for reply capture
  - `session/cancel` notification → `stopReason=cancelled` → `TurnStatus::Interrupted`
  - Hard rule: interrupt path never surfaces `TurnStatus::Completed` /
    `DeliveryState::Completed`
- Live gated test: `tests/acp_smoke.rs` (`PHAROS_RUST_ADAPTER_AGY_PRODUCT_PATH_TEST=1`)

### Interface issue / contract-bump proposal (do not block this stream)

Promote into Phase 0.x (`pharos-protocol` / `pharos-api`), do **not** invent forks:

1. `SessionAdapter` trait (+ `StartSessionRequest`, `PromptMode`, `TurnStatus`,
   `TurnOutcome`, `InterruptOutcome`) — currently duplicated in S5a + S5c
2. `DeliveryWorker` trait (+ `DeliveryJob`, `DeliveryDispatchResult`)
3. Optional: shared `AdapterError`

Until then, S2 should pick one crate as the trait source or depend on mirrors
with identical shapes. **This stream did not move the traits.**

## Gate commands + summary

```sh
cd rust
cargo fmt -p pharos-adapter-agy -- --check          # OK
cargo clippy -p pharos-adapter-agy --all-targets -- -D warnings  # OK
cargo test -p pharos-adapter-agy                    # 4 lib + gated smoke skip OK
for i in 1 2 3; do
  PHAROS_RUST_ADAPTER_AGY_PRODUCT_PATH_TEST=1 \
  PHAROS_AGY_TEST_MODEL=gemini-3.8-flash \
    cargo test -p pharos-adapter-agy --test acp_smoke -- --nocapture || break
done
# → SUMMARY pass=3 fail=0; seed+DONE Completed; interrupt=Interrupted (not Completed)
```

## Evidence

- `internal/evidence/2026-11-10-rust-adapter-agy-acp-smoke.md` (3× PASS table + commands)
- Live sidecars (msg-test), e.g.:
  `~/personal/pharos-msg-test/peer-phase-a/rust-adapter-agy-*/acp-smoke.txt`

## PASS / PARTIAL / NOT-TESTED

| Item | Mark | Reason |
|---|---|---|
| ACP start session (`session/new`) via `SessionAdapter` | PASS | Live 3× |
| One prompt round-trip → `Completed` with reply captured | PASS | Seed marker `PHAROS_RUST_ADAPTER_AGY_SEED` + delivery `…_DONE` |
| Interrupt never maps to `Completed` | PASS | `stopReason=cancelled` → `Interrupted`; synthetic delivery `Failed` |
| `DeliveryWorker::dispatch` Completed with assistant text | PASS | Live 3× |
| Default `gemini-4-argon-medium` product path | PARTIAL | Host individual quota exhausted (~85h reset) during bring-up; gate pins `gemini-3.8-flash` via `session/set_config_option` |
| Isolated `--gemini-dir` under msg-test without default home | PARTIAL | API present (`connect_isolated` + seed); incomplete seed surfaced auth/quota ghosts — live gate uses default `~/.gemini` auth (CLI-owned), workspace isolated |
| Full Swift Host binder → Mesh `replyOnce` via Rust adapter | NOT-TESTED | Stream owns Rust adapter only; Host binder remains captain/S2 |
| `pharos-meshd` registration of Agy `dyn SessionAdapter` | NOT-TESTED | `main.rs` captain-owned; wiring snippet only |
| HITL / `session/request_permission` round-trip | NOT-TESTED | Product path uses `--dangerously-skip-permissions`; S2 HITL owns approvals |
| Steer mid-turn live | NOT-TESTED | API present (`PromptMode::Steer`); not exercised in this gate |
| Transcript.jsonl Attached/read-only supervisor path | NOT-TESTED | Out of stream gate (ACP stdio is primary) |

## Wiring

See `docs/wiring-adapter-agy.md`. **wiring-local** commit appends
`crates/pharos-adapter-agy` to `rust/Cargo.toml` members so the crate builds;
captain owns the permanent member list. No `agent-runtime` `main.rs` edit.

STATUS: ADAPTER-AGY-DONE
