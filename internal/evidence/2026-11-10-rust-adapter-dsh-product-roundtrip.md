# Evidence — S5b Rust adapter-dsh product round-trip

**Stream:** ADAPTER-DSH (S5b)  
**Host:** Grok Bot box (Linux)  
**Date:** 2026-11-10  
**dsh:** `0.2.2-rc.1` (`/home/box/.local/bin/dsh`)  
**Contracts pin:** `CONTRACTS_VERSION=0.1.0` (Batch 1 base; not edited)

## Gate

Isolated `dsh web` Host driven through Rust `DshSessionAdapter` / `DeliveryWorker`
(seed → Completed with assistant text; interrupt → Interrupted/Failed, never Completed).
Never uses the shared 3080 Host / its token / ipc.sock / workspace.json.

```sh
cd rust
cargo fmt -p pharos-adapter-dsh -- --check
cargo clippy -p pharos-adapter-dsh --all-targets -- -D warnings
cargo test -p pharos-adapter-dsh

# Live (CI skips unless env set); ≥3×:
for i in 1 2 3; do
  PHAROS_RUST_ADAPTER_DSH_PRODUCT_PATH_TEST=1 \
    cargo test -p pharos-adapter-dsh --test product_roundtrip -- --nocapture || break
done
```

Raw series log: `internal/evidence/2026-11-10-rust-adapter-dsh-product-roundtrip-runs.txt`

### 3× live series

| Run | Session | Seed | Delivery | Interrupt |
|---|---|---|---|---|
| 1 | `session-a5615bb0-6482-433b-908e-07c1c4526fb3` | Completed / `PHAROS_RUST_ADAPTER_DSH_SEED` | Completed / `PHAROS_RUST_ADAPTER_DSH_DONE` | Interrupted |
| 2 | `session-9ec95ab5-b2a4-4ea1-932a-4585b438ba42` | Completed / SEED | Completed / DONE | Interrupted |
| 3 | `session-14b2c046-87f5-49c2-b29a-69e7c94d3af8` | Completed / SEED | Completed / DONE | Interrupted |

**SUMMARY: pass=3 fail=0** (~6–11s/run)

3080 Host remained running after the series (untouched).

### Latest sidecar (msg-test, no secrets)

`~/personal/pharos-msg-test/peer-phase-a/rust-adapter-dsh-1794344454091178730/product-roundtrip.txt`

```
dsh_version=0.2.2-rc.1
session=session-14b2c046-87f5-49c2-b29a-69e7c94d3af8
seed_status=Completed
seed_preview=PHAROS_RUST_ADAPTER_DSH_SEED
delivery_state=Completed
delivery_detail=DSH turn turn_2 completed
delivery_reply_preview=PHAROS_RUST_ADAPTER_DSH_DONE
interrupt_status=Some(Interrupted)
interrupt_not_completed=true
mid_interrupt_status=Some(Interrupted)
synthetic_delivery_state=Failed
```

## Assertions covered

| Check | Result |
|---|---|
| Real isolated `dsh web` (port 0, private `DSH_HOME`) | PASS (3/3) |
| Seed prompt → Completed + assistant text | PASS (3/3) |
| `DeliveryWorker` → `DeliveryState::Completed` + DONE marker | PASS (3/3) |
| Interrupt → `Interrupted` (**never** Completed) | PASS (3/3) |
| Interrupt delivery synthetic → `DeliveryState::Failed` | PASS |
| Confined to `pharos-msg-test/.../rust-adapter-dsh-*` | PASS |
| Shared 3080 Host left alone | PASS |

## Build gates

```
cargo fmt -p pharos-adapter-dsh -- --check          # OK
cargo clippy -p pharos-adapter-dsh --all-targets -- -D warnings  # OK
cargo test -p pharos-adapter-dsh                    # 7 lib + gated integration skip OK
```

## Notes

- Host launch: `dsh --profile web --patch <model.patch> --no-open --port 0 --host 127.0.0.1`
  (launcher `--patch` before web flags; `dsh web --patch …` is rejected on 0.2.2-rc.1).
- Auth seed: copy `~/.dsh/.credentials.yaml` (+ anonymous id) into isolated home; inject
  `OPENCODE_GO_API_KEY` from credentials/env (never logged).
- Cancel end reason `aborted` mapped to `TurnStatus::Interrupted`.
- yolo → `/permission danger-full-access` (0.2.2-rc.1 preset names).
