# Handoff — S5b adapter-dsh (ADAPTER-DSH)

**Branch:** `rust/adapter-dsh`  
**Worktree:** `~/personal/pharos-wt/adapter-dsh`  
**Exclusive dirs:** `rust/crates/pharos-adapter-dsh/` (+ wiring-local workspace member append)  
**Contracts:** frozen `0.1.0` — **not edited**

## What shipped

New crate `pharos-adapter-dsh`:

- **`DshSessionAdapter`** — thin client over an isolated `dsh web` Host
  (HTTP cookie connect + `/api/session/*` + `session/page` journal poll)
- Implements shared **`SessionAdapter`** + **`DeliveryWorker`** from
  `pharos-codex-adapter` (same shape as S5a; see interface issue below)
- Host spawn: private `DSH_HOME` under
  `~/personal/pharos-msg-test/peer-phase-a/rust-adapter-dsh-<ts>/`, credentials
  seeded, model patch for `opencode-go` / `deepseek-v4.1-flash`, port `0`
- Hard rule: interrupt / `aborted` → `Interrupted` or delivery `Failed`,
  **never** `Completed`
- Live gated test: `tests/product_roundtrip.rs`

### Interface issue (do not move in this stream)

`SessionAdapter` / `DeliveryWorker` still live in `pharos-codex-adapter`.
S5b depends on that crate for the trait surface so S2 can share one `dyn`
type. **Proposal for Phase 0.x:** promote those traits (+ `AdapterError`,
job/result types) into `pharos-protocol` / `pharos-api`. Until then, keep
consuming the Codex crate location (mirrors S5a handoff).

### wiring-local

`rust/Cargo.toml` members append for `crates/pharos-adapter-dsh` (and workspace
dep path). Captain owns final member list / `agent-runtime` hooks — see
`docs/wiring-adapter-dsh.md`. No `main.rs` edit.

## Gate commands + summary

```sh
cd rust
cargo fmt -p pharos-adapter-dsh -- --check          # OK
cargo clippy -p pharos-adapter-dsh --all-targets -- -D warnings  # OK
cargo test -p pharos-adapter-dsh                    # 7 lib + skip gated live

for i in 1 2 3; do
  PHAROS_RUST_ADAPTER_DSH_PRODUCT_PATH_TEST=1 \
    cargo test -p pharos-adapter-dsh --test product_roundtrip -- --nocapture || break
done
# → SUMMARY pass=3 fail=0; seed+DONE Completed; interrupt=Interrupted
```

## Evidence

- `internal/evidence/2026-11-10-rust-adapter-dsh-product-roundtrip.md`
- `internal/evidence/2026-11-10-rust-adapter-dsh-product-roundtrip-runs.txt`
- Live sidecars (msg-test):
  `~/personal/pharos-msg-test/peer-phase-a/rust-adapter-dsh-*/product-roundtrip.txt`

## PASS / PARTIAL / NOT-TESTED

| Item | Mark | Reason |
|---|---|---|
| Isolated seed prompt → Completed + captured assistant text | PASS | 3/3 live |
| `DeliveryWorker` product turn → Completed + DONE marker | PASS | 3/3 live |
| Interrupt → Interrupted/Failed, never Completed | PASS | 3/3; `aborted`→Interrupted |
| Unit/fmt/clippy | PASS | green |
| Shared 3080 Host / token / ipc.sock untouched | PASS | host still on 3080 after series |
| Full Swift Host binder → Mesh `replyOnce` via Rust adapter | NOT-TESTED | Stream owns Rust adapter only; binder/S2/captain |
| `pharos-meshd` registers `DshSessionAdapter` | NOT-TESTED | `main.rs` captain-owned; wiring snippet only |
| WebSocket `session/follow` live streaming path | NOT-TESTED | Product gate uses journal `session/page` (Swift seed path) |
| HITL / permission ask mid-turn | NOT-TESTED | yolo/`danger-full-access` for product path; S2 HITL |
| Steer mid-turn live | NOT-TESTED | `PromptMode::Steer` wired on HTTP; not live-exercised |
| Plugin / Broker delivery path | NOT-TESTED | Host-owned thin client only (no dsh-plugin-pharos) |

## Wiring

See `docs/wiring-adapter-dsh.md`.

STATUS: ADAPTER-DSH-DONE
