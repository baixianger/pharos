# Evidence — S5d adapter-cursor product round-trip

- host: Xiangs-Mac-mini.home
- time: 2026-11-10T21:56:44+01:00
- agent: 2026.11.05-86047df
- gate: PHAROS_RUST_ADAPTER_CURSOR_PRODUCT_PATH_TEST=1
- workspace pattern: ~/personal/pharos-msg-test/peer-phase-a/rust-adapter-cursor-<ts>/

## Commands
```
cd rust
for i in 1 2 3; do
  PHAROS_RUST_ADAPTER_CURSOR_PRODUCT_PATH_TEST=1 \
    cargo test -p pharos-adapter-cursor --test product_roundtrip -- --nocapture || break
done
```

## Runs
### Run 1
```
    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.16s
     Running tests/product_roundtrip.rs (target/debug/deps/product_roundtrip-40ea512a6859f3f8)

running 2 tests
test list_chats_is_explicit_unsupported ... ok
Cursor agent version: 2026.11.05-86047df
Host product-path Cursor Session (Rust): chat=d5a8b426-beab-4557-8bca-f68d4cbf72bf
Host Cursor product-path seed turn=de0f40fd-a015-4cb2-acc9-efc9c165130f
Host Cursor product-path seed outcome: status=Completed raw=completed error=None preview="PHAROS_RUST_ADAPTER_CURSOR_SEED"
Host Cursor product-path delivery: state=Completed detail=Cursor turn 20dd70c6-020c-46b3-816e-edafcffcc539 completed turn=Some("20dd70c6-020c-46b3-816e-edafcffcc539") assistant=Some("PHAROS_RUST_ADAPTER_CURSOR_DONE")
Host Cursor interrupt: turn=Some("1147f927-c33c-49d8-99f1-9f1385bead21") status=Some(Interrupted)
Host Cursor local turns observed: de0f40fd-a015-4cb2-acc9-efc9c165130f:Completed | 20dd70c6-020c-46b3-816e-edafcffcc539:Completed | 1147f927-c33c-49d8-99f1-9f1385bead21:Interrupted
agent_version=2026.11.05-86047df
session=d5a8b426-beab-4557-8bca-f68d4cbf72bf
vendor_thread=d5a8b426-beab-4557-8bca-f68d4cbf72bf
seed_status=Completed
seed_preview=PHAROS_RUST_ADAPTER_CURSOR_SEED
delivery_id=0fa6e951-9e3a-445a-810b-57a3133f35a9
delivery_state=Completed
delivery_detail=Cursor turn 20dd70c6-020c-46b3-816e-edafcffcc539 completed
delivery_reply_preview=PHAROS_RUST_ADAPTER_CURSOR_DONE
interrupt_status=Some(Interrupted)
interrupt_not_completed=true
synthetic_delivery_state=Failed
steer_unsupported=1
workdir=/Users/baixianger/personal/pharos-msg-test/peer-phase-a/rust-adapter-cursor-1794344205352238000/cursor-work

Host Cursor product-path: route=accepted phase=replied runtime-completed=1 workdir=/Users/baixianger/personal/pharos-msg-test/peer-phase-a/rust-adapter-cursor-1794344205352238000/cursor-work
test product_roundtrip_resume_and_interrupt_never_completed ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 19.83s
```
exit=0

### Run 2
```
    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.12s
     Running tests/product_roundtrip.rs (target/debug/deps/product_roundtrip-40ea512a6859f3f8)

running 2 tests
test list_chats_is_explicit_unsupported ... ok
Cursor agent version: 2026.11.05-86047df
Host product-path Cursor Session (Rust): chat=1cab33a8-5a5a-4d68-a177-55b75a153397
Host Cursor product-path seed turn=2e17de42-a834-43d6-b489-6b11d073fd04
Host Cursor product-path seed outcome: status=Completed raw=completed error=None preview="PHAROS_RUST_ADAPTER_CURSOR_SEED"
Host Cursor product-path delivery: state=Completed detail=Cursor turn 8b06c2fa-6900-40df-b2b0-00a3f319a47c completed turn=Some("8b06c2fa-6900-40df-b2b0-00a3f319a47c") assistant=Some("PHAROS_RUST_ADAPTER_CURSOR_DONE")
Host Cursor interrupt: turn=Some("cf4e8da0-35c9-4faf-8988-cd1a166bcba7") status=Some(Interrupted)
Host Cursor local turns observed: 2e17de42-a834-43d6-b489-6b11d073fd04:Completed | 8b06c2fa-6900-40df-b2b0-00a3f319a47c:Completed | cf4e8da0-35c9-4faf-8988-cd1a166bcba7:Interrupted
agent_version=2026.11.05-86047df
session=1cab33a8-5a5a-4d68-a177-55b75a153397
vendor_thread=1cab33a8-5a5a-4d68-a177-55b75a153397
seed_status=Completed
seed_preview=PHAROS_RUST_ADAPTER_CURSOR_SEED
delivery_id=3c6713e1-3d71-49aa-aab2-0257cb2f4386
delivery_state=Completed
delivery_detail=Cursor turn 8b06c2fa-6900-40df-b2b0-00a3f319a47c completed
delivery_reply_preview=PHAROS_RUST_ADAPTER_CURSOR_DONE
interrupt_status=Some(Interrupted)
interrupt_not_completed=true
synthetic_delivery_state=Failed
steer_unsupported=1
workdir=/Users/baixianger/personal/pharos-msg-test/peer-phase-a/rust-adapter-cursor-1794344225375305000/cursor-work

Host Cursor product-path: route=accepted phase=replied runtime-completed=1 workdir=/Users/baixianger/personal/pharos-msg-test/peer-phase-a/rust-adapter-cursor-1794344225375305000/cursor-work
test product_roundtrip_resume_and_interrupt_never_completed ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 17.95s
```
exit=0

### Run 3
```
    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.05s
     Running tests/product_roundtrip.rs (target/debug/deps/product_roundtrip-40ea512a6859f3f8)

running 2 tests
test list_chats_is_explicit_unsupported ... ok
Cursor agent version: 2026.11.05-86047df
Host product-path Cursor Session (Rust): chat=8a3d9a2c-b6c5-4205-b2c9-4fe41bb92e9a
Host Cursor product-path seed turn=249b30ff-22d5-48cb-844f-e9a9eb7359eb
Host Cursor product-path seed outcome: status=Completed raw=completed error=None preview="PHAROS_RUST_ADAPTER_CURSOR_SEED"
Host Cursor product-path delivery: state=Completed detail=Cursor turn 08379bb4-1a54-4b23-8d2c-98a48ea0d9b6 completed turn=Some("08379bb4-1a54-4b23-8d2c-98a48ea0d9b6") assistant=Some("PHAROS_RUST_ADAPTER_CURSOR_DONE")
Host Cursor interrupt: turn=Some("fdfc2927-3fc7-4b98-87b2-230bd303f260") status=Some(Interrupted)
Host Cursor local turns observed: 249b30ff-22d5-48cb-844f-e9a9eb7359eb:Completed | 08379bb4-1a54-4b23-8d2c-98a48ea0d9b6:Completed | fdfc2927-3fc7-4b98-87b2-230bd303f260:Interrupted
agent_version=2026.11.05-86047df
session=8a3d9a2c-b6c5-4205-b2c9-4fe41bb92e9a
vendor_thread=8a3d9a2c-b6c5-4205-b2c9-4fe41bb92e9a
seed_status=Completed
seed_preview=PHAROS_RUST_ADAPTER_CURSOR_SEED
delivery_id=e9b1d445-fe6f-4abb-98db-1542a064aca2
delivery_state=Completed
delivery_detail=Cursor turn 08379bb4-1a54-4b23-8d2c-98a48ea0d9b6 completed
delivery_reply_preview=PHAROS_RUST_ADAPTER_CURSOR_DONE
interrupt_status=Some(Interrupted)
interrupt_not_completed=true
synthetic_delivery_state=Failed
steer_unsupported=1
workdir=/Users/baixianger/personal/pharos-msg-test/peer-phase-a/rust-adapter-cursor-1794344243445054000/cursor-work

Host Cursor product-path: route=accepted phase=replied runtime-completed=1 workdir=/Users/baixianger/personal/pharos-msg-test/peer-phase-a/rust-adapter-cursor-1794344243445054000/cursor-work
test product_roundtrip_resume_and_interrupt_never_completed ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 18.78s
```
exit=0

## Summary
pass=3 fail=0 (target >=3 pass)

## Sidecar dirs
/Users/baixianger/personal/pharos-msg-test/peer-phase-a/rust-adapter-cursor-1794344243445054000
/Users/baixianger/personal/pharos-msg-test/peer-phase-a/rust-adapter-cursor-1794344225375305000
/Users/baixianger/personal/pharos-msg-test/peer-phase-a/rust-adapter-cursor-1794344205352238000
/Users/baixianger/personal/pharos-msg-test/peer-phase-a/rust-adapter-cursor-probe-1794343915
/Users/baixianger/personal/pharos-msg-test/peer-phase-a/rust-adapter-cursor-interrupt-1794343979

## Latest sidecar excerpt (/Users/baixianger/personal/pharos-msg-test/peer-phase-a/rust-adapter-cursor-1794344243445054000/product-roundtrip.txt)
```
agent_version=2026.11.05-86047df
session=8a3d9a2c-b6c5-4205-b2c9-4fe41bb92e9a
vendor_thread=8a3d9a2c-b6c5-4205-b2c9-4fe41bb92e9a
seed_status=Completed
seed_preview=PHAROS_RUST_ADAPTER_CURSOR_SEED
delivery_id=e9b1d445-fe6f-4abb-98db-1542a064aca2
delivery_state=Completed
delivery_detail=Cursor turn 08379bb4-1a54-4b23-8d2c-98a48ea0d9b6 completed
delivery_reply_preview=PHAROS_RUST_ADAPTER_CURSOR_DONE
interrupt_status=Some(Interrupted)
interrupt_not_completed=true
synthetic_delivery_state=Failed
steer_unsupported=1
workdir=/Users/baixianger/personal/pharos-msg-test/peer-phase-a/rust-adapter-cursor-1794344243445054000/cursor-work
```
