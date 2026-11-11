# Evidence — S5c adapter-agy ACP smoke

- Date: 2026-11-10T21:10:15Z
- Host: grok-bot-vm-51054904 (Linux 6.12.113+ x86_64)
- agy: 1.5.5 at /home/box/.local/bin/agy
- Gate env: PHAROS_RUST_ADAPTER_AGY_PRODUCT_PATH_TEST=1
- Model: `gemini-3.8-flash` (argon individual quota exhausted on this Host)
- Crate: pharos-adapter-agy

## Runs

### Run 1 — PASS

```
    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.06s
     Running tests/acp_smoke.rs (target/debug/deps/acp_smoke-aa7a805d1d412fb9)

running 1 test
Host Agy ACP model=gemini-3.8-flash
Host Agy ACP Session (Rust): 9909366a-b254-435f-9c50-4c19b95df6e1
Host Agy ACP seed turn=agy-turn-4
Host Agy ACP seed outcome: status=Completed raw=end_turn error=None preview="PHAROS_RUST_ADAPTER_AGY_SEED"
Host Agy ACP delivery: state=Completed detail=Agy turn agy-turn-5 completed turn=Some("agy-turn-5") assistant=Some("PHAROS_RUST_ADAPTER_AGY_DONE")
Host Agy interrupt: turn=Some("agy-turn-6") status=Some(Interrupted)
Host Agy ACP smoke: route=accepted phase=replied runtime-completed=1 workdir=/home/box/personal/pharos-msg-test/peer-phase-a/rust-adapter-agy-1794345015585378632/agy-work
test acp_roundtrip_and_interrupt_never_completed ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 8.42s

```

Sidecar: `/home/box/personal/pharos-msg-test/peer-phase-a/rust-adapter-agy-1794345015585378632/acp-smoke.txt`

```
agy_version=1.5.5
session=9909366a-b254-435f-9c50-4c19b95df6e1
seed_status=Completed
seed_preview=PHAROS_RUST_ADAPTER_AGY_SEED
delivery_id=d6d9f779-e350-4394-9783-943168b36bc1
delivery_state=Completed
delivery_detail=Agy turn agy-turn-5 completed
delivery_reply_preview=PHAROS_RUST_ADAPTER_AGY_DONE
interrupt_status=Some(Interrupted)
interrupt_not_completed=true
mid_interrupt_status=Some(Interrupted)
synthetic_delivery_state=Failed
workdir=/home/box/personal/pharos-msg-test/peer-phase-a/rust-adapter-agy-1794345015585378632/agy-work
gemini_dir=default:~/.gemini
```

### Run 2 — PASS

```
    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.07s
     Running tests/acp_smoke.rs (target/debug/deps/acp_smoke-aa7a805d1d412fb9)

running 1 test
Host Agy ACP model=gemini-3.8-flash
Host Agy ACP Session (Rust): 4c947f77-dd31-45fd-97e1-9416f233ce2a
Host Agy ACP seed turn=agy-turn-4
Host Agy ACP seed outcome: status=Completed raw=end_turn error=None preview="PHAROS_RUST_ADAPTER_AGY_SEED"
Host Agy ACP delivery: state=Completed detail=Agy turn agy-turn-5 completed turn=Some("agy-turn-5") assistant=Some("PHAROS_RUST_ADAPTER_AGY_DONE")
Host Agy interrupt: turn=Some("agy-turn-6") status=Some(Interrupted)
Host Agy ACP smoke: route=accepted phase=replied runtime-completed=1 workdir=/home/box/personal/pharos-msg-test/peer-phase-a/rust-adapter-agy-1794345024123511880/agy-work
test acp_roundtrip_and_interrupt_never_completed ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 5.26s

```

Sidecar: `/home/box/personal/pharos-msg-test/peer-phase-a/rust-adapter-agy-1794345024123511880/acp-smoke.txt`

```
agy_version=1.5.5
session=4c947f77-dd31-45fd-97e1-9416f233ce2a
seed_status=Completed
seed_preview=PHAROS_RUST_ADAPTER_AGY_SEED
delivery_id=62207445-81f9-469b-88ea-572a50bd89de
delivery_state=Completed
delivery_detail=Agy turn agy-turn-5 completed
delivery_reply_preview=PHAROS_RUST_ADAPTER_AGY_DONE
interrupt_status=Some(Interrupted)
interrupt_not_completed=true
mid_interrupt_status=Some(Interrupted)
synthetic_delivery_state=Failed
workdir=/home/box/personal/pharos-msg-test/peer-phase-a/rust-adapter-agy-1794345024123511880/agy-work
gemini_dir=default:~/.gemini
```

### Run 3 — PASS

```
    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.09s
     Running tests/acp_smoke.rs (target/debug/deps/acp_smoke-aa7a805d1d412fb9)

running 1 test
Host Agy ACP model=gemini-3.8-flash
Host Agy ACP Session (Rust): c3a5876a-99da-4268-80ec-a275ac3aa163
Host Agy ACP seed turn=agy-turn-4
Host Agy ACP seed outcome: status=Completed raw=end_turn error=None preview="PHAROS_RUST_ADAPTER_AGY_SEED"
Host Agy ACP delivery: state=Completed detail=Agy turn agy-turn-5 completed turn=Some("agy-turn-5") assistant=Some("PHAROS_RUST_ADAPTER_AGY_DONE")
Host Agy interrupt: turn=Some("agy-turn-6") status=Some(Interrupted)
Host Agy ACP smoke: route=accepted phase=replied runtime-completed=1 workdir=/home/box/personal/pharos-msg-test/peer-phase-a/rust-adapter-agy-1794345029522814259/agy-work
test acp_roundtrip_and_interrupt_never_completed ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 5.05s

```

Sidecar: `/home/box/personal/pharos-msg-test/peer-phase-a/rust-adapter-agy-1794345029522814259/acp-smoke.txt`

```
agy_version=1.5.5
session=c3a5876a-99da-4268-80ec-a275ac3aa163
seed_status=Completed
seed_preview=PHAROS_RUST_ADAPTER_AGY_SEED
delivery_id=754332d3-b834-47a9-a414-7cc18fc29170
delivery_state=Completed
delivery_detail=Agy turn agy-turn-5 completed
delivery_reply_preview=PHAROS_RUST_ADAPTER_AGY_DONE
interrupt_status=Some(Interrupted)
interrupt_not_completed=true
mid_interrupt_status=Some(Interrupted)
synthetic_delivery_state=Failed
workdir=/home/box/personal/pharos-msg-test/peer-phase-a/rust-adapter-agy-1794345029522814259/agy-work
gemini_dir=default:~/.gemini
```

## Summary

pass=3 fail=0 (target ≥3 PASS)

## Gate commands

```sh
cd rust
cargo fmt -p pharos-adapter-agy -- --check
cargo clippy -p pharos-adapter-agy --all-targets -- -D warnings
cargo test -p pharos-adapter-agy
for i in 1 2 3; do
  PHAROS_RUST_ADAPTER_AGY_PRODUCT_PATH_TEST=1 \
  PHAROS_AGY_TEST_MODEL=gemini-3.8-flash \
    cargo test -p pharos-adapter-agy --test acp_smoke -- --nocapture || break
done
```

## Notes

- Default `gemini-4-argon-medium` returned individual-quota end_turn on this Host during bring-up; live gate pins `gemini-3.8-flash` via `session/set_config_option`.
- Interrupt maps `stopReason=cancelled` → `TurnStatus::Interrupted`; never `Completed`.
- Workspace/evidence under `~/personal/pharos-msg-test/peer-phase-a/rust-adapter-agy-<ts>/`; default `~/.gemini` auth only (CLI-owned).
