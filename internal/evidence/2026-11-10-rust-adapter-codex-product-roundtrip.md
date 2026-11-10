# Evidence — S5a Rust adapter-codex product round-trip

**Stream:** ADAPTER-CODEX (S5a)  
**Host:** MacBook Air (`mac-air`)  
**Date:** 2026-11-10  
**Codex CLI:** `codex-cli 0.167.0` (`/opt/homebrew/bin/codex`)  
**Contracts pin:** `CONTRACTS_VERSION=0.1.0` / tag `rust-contracts-0.1.0` / commit `88f4c22`

## Gate

Equivalent of Swift `PHAROS_HOST_THREAD_CODEX_PRODUCT_PATH_TEST`, exercised **through the Rust adapter library** (`CodexSessionAdapter` + `DeliveryWorker`), not the Swift Host binder.

```sh
cd rust
unset CODEX_HOME
PHAROS_RUST_ADAPTER_CODEX_PRODUCT_PATH_TEST=1 \
  cargo test -p pharos-codex-adapter --test product_roundtrip -- --nocapture
```

## PM re-review follow-up (2026-11-10 ~20:45+)

PM observed 4/5 prior passes with one unexplained `dispatch.state=Failed` (detail not captured).

### Fixes landed

1. **Diagnostics:** test prints `dispatch.detail`, assistant preview, and a turns snapshot *before* asserting Completed; Failed results carry real Codex turn status / vendor error via `TurnOutcome::failure_detail()`.
2. **Idle race fix (real flake, not blind retry):** `wait_until_idle` + Queue `send_prompt` now settle on thread idle using `thread/read` with `includeTurns: false`. An earlier idle helper used `includeTurns: true`, which Codex 0.167 rejects on empty threads with `list_turns is not supported yet` (reproduced 5/5 as seed `turn/start` timeouts). Never maps Failed→Completed.
3. **5× live re-run after fix:** **pass=5 fail=0**.

### 5× live series (post-fix)

| Run | Session | Delivery | Interrupt |
|---|---|---|---|
| 1 | `01a1c6fd-354d-7790-b475-5aa86807c596` | Completed / `PHAROS_RUST_ADAPTER_CODEX_DONE` | Interrupted |
| 2 | `01a1c6fd-52d2-73d1-837e-764e824a877b` | Completed / DONE | Interrupted |
| 3 | `01a1c6fd-855c-78b1-84cf-8aa449703b16` | Completed / DONE | Interrupted |
| 4 | `01a1c6fd-a62c-7941-a6f4-af7ab62f0f94` | Completed / DONE | Interrupted |
| 5 | `01a1c6fd-c54f-7ea2-acaa-5d16b3d7a7ea` | Completed / DONE | Interrupted |

**SUMMARY: pass=5 fail=0**

Pre-fix diagnostic attempt (idle with `includeTurns: true`) failed 5/5 at seed with:

```
timed out waiting for Codex thread idle (... last read error: list_turns is not supported yet)
```

That confirmed the idle helper bug; it is fixed. The original single PM failure (`dispatch.state=Failed`) still has no captured vendor detail from that run; post-fix series did not reproduce it.

### Latest sidecar (msg-test, no secrets)

`~/personal/pharos-msg-test/peer-phase-a/rust-adapter-codex-1794339882268926000/product-roundtrip.txt`

```
codex_version=codex-cli 0.167.0
session=01a1c6fd-c54f-7ea2-acaa-5d16b3d7a7ea
seed_status=Completed
seed_preview=PHAROS_RUST_ADAPTER_CODEX_SEED
delivery_state=Completed
delivery_detail=Codex turn 01a1c6fd-d27c-7d43-9244-269504e532e4 completed
delivery_reply_preview=PHAROS_RUST_ADAPTER_CODEX_DONE
interrupt_status=Some(Interrupted)
interrupt_not_completed=true
synthetic_delivery_state=Failed
```

## Assertions covered

| Check | Result |
|---|---|
| Real Codex CLI 0.167 receives message | PASS (5/5) |
| Reply comes back through Rust adapter | PASS (`PHAROS_RUST_ADAPTER_CODEX_DONE`, 5/5) |
| Delivery success → `DeliveryState::Completed` | PASS (5/5) |
| Interrupt → vendor `interrupted`, **not** `completed` | PASS (5/5) |
| Interrupt delivery outcome → `DeliveryState::Failed` (never Completed) | PASS |
| Confined to `pharos-msg-test` workdir | PASS |
| Failed results carry vendor detail | PASS (code path; exercised by unit + assert messages) |

## Build gates

```
cargo fmt -p pharos-codex-adapter -- --check   # OK
cargo clippy -p pharos-codex-adapter --all-targets -- -D warnings  # OK
cargo test -p pharos-codex-adapter --lib --bins  # 5 passed
```

## Notes

- Transport: isolated `codex app-server` **stdio** (Swift `CodexStdioTransport` equivalent).
- Auth uses default `~/.codex` (CODEX_HOME explicitly unset for the child). No tokens printed.
- Full Host binder → Mesh `replyOnce` room persistence remains integration/captain + S2.
