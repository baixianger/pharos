# Evidence: S3 box headless mesh + Runtime Peer call

**Date:** 2026-11-10  
**Host:** grok-bot (Linux)  
**Data dir:** `/home/box/personal/pharos-msg-test/rust-mesh-iroh-box` (msg-test only)

## Command

```sh
./Scripts/smoke-mesh-iroh-box.sh
```

## Result (excerpt)

```
BOX_HEADLESS_PEER_CALL_OK c8109c95-c3ae-47f0-8738-70781546475e
TRUST_PAIRING_OK 40b8e6c5-167a-4349-b7b1-de8f3069796b
SMOKE_BOX_DONE data=/home/box/personal/pharos-msg-test/rust-mesh-iroh-box
```

## What was proven

1. `pharos-meshd` on non-default Unix socket under msg-test data-dir.
2. Driver + conversation register for `member-mesh-1`.
3. Host `pharos-mesh-node serve --relay-disabled` with `--runtime-socket`.
4. Client Peer `host.runtime.call.v1` → allowlisted `delivery.submit-member` → Runtime delivery **queued** (`submitted: true`).
5. Trust invite/accept crypto smoke (`pharos-trust1:` ticket) wrote acceptance under msg-test.

## Logs on disk

- `.../rust-mesh-iroh-box/logs/host-serve.json`
- `.../rust-mesh-iroh-box/logs/peer-call.json`
- `.../rust-mesh-iroh-box/logs/pair-accept.json`
- `/tmp/smoke-mesh-iroh-box-final.log`
