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

### Result (real / live)

```
Host product-path Codex Session (Rust): 01a1c6bf-d418-7cd0-a258-89048e8fe9ba
Host Codex product-path seed turn=01a1c6bf-d76f-7391-9cb2-d1aa1322663f
Host Codex product-path delivery: state=Completed detail=Codex turn 01a1c6bf-e7bc-7f52-bf4a-fc561a6c575d completed ...
Host Codex interrupt: turn=Some("01a1c6bf-effa-7cd1-80f5-10e68c848125") status=Some(Interrupted)
Host Codex product-path: route=accepted phase=replied runtime-completed=1
test product_roundtrip_and_interrupt_never_completed ... ok
finished in 8.06s
```

### Sidecar (msg-test only, no secrets)

Path: `~/personal/pharos-msg-test/peer-phase-a/rust-adapter-codex-1794335822/product-roundtrip.txt`

```
codex_version=codex-cli 0.167.0
session=01a1c6bf-d418-7cd0-a258-89048e8fe9ba
seed_status=Completed
seed_preview=PHAROS_RUST_ADAPTER_CODEX_SEED
delivery_id=de15bfca-9496-41d9-a825-5e154f795652
delivery_state=Completed
delivery_reply_preview=PHAROS_RUST_ADAPTER_CODEX_DONE
interrupt_status=Some(Interrupted)
interrupt_not_completed=true
mid_interrupt_status=Some(Interrupted)
synthetic_delivery_state=Failed
```

## Assertions covered

| Check | Result |
|---|---|
| Real Codex CLI 0.167 receives message | PASS (seed + delivery turns) |
| Reply comes back through Rust adapter | PASS (`PHAROS_RUST_ADAPTER_CODEX_DONE`) |
| Delivery success → `DeliveryState::Completed` | PASS |
| Interrupt → vendor `interrupted`, **not** `completed` | PASS |
| Interrupt delivery outcome → `DeliveryState::Failed` (never Completed) | PASS |
| Confined to `pharos-msg-test` workdir | PASS |

## Build gates

```
cargo fmt -p pharos-codex-adapter -- --check   # OK
cargo clippy -p pharos-codex-adapter --all-targets -- -D warnings  # OK
cargo test -p pharos-codex-adapter --lib --bins  # 5 passed
```

## Notes

- Transport: isolated `codex app-server` **stdio** (Swift `CodexStdioTransport` equivalent), not the shared daemon proxy, so the builtin Runtime worker cannot steal deliveries.
- Auth uses default `~/.codex` (CODEX_HOME explicitly unset for the child). No tokens printed.
- Full Host binder → Mesh `replyOnce` room persistence remains a Swift/Runtime integration concern for the merge captain / S2; this stream proves the Rust adapter product path end-to-end against Codex.
