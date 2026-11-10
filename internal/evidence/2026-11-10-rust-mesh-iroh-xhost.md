# Evidence: S3 XHOST mini↔air via Rust mesh Peer call

**Date:** 2026-11-10  
**Scratch clones:** `~/personal/pharos-wt/mesh-iroh-peer` on mini and air  
**Data dirs:** `~/personal/pharos-msg-test/rust-mesh-iroh-peer-*` only  
**Method:** git bundle + WIP tarball from box worktree; build `pharos-mesh` + `pharos-meshd` on each Mac.

## mini → air

- Air host: `pharos-meshd` + `pharos-mesh-node serve` under `rust-mesh-iroh-peer-air`
- Device `7396a111-…`, endpoint `35b22ee1…`, trust group `283d8ebe-…`
- Mini client Peer call `--relay-disabled` with air `EndpointAddr` (LAN/Tailscale/public addrs)
- Result:

```
XHOST_MINI_TO_AIR_OK a9eb0bb8-3368-4ed7-9a75-bd6034fe4072
```

Delivery state on air Runtime: `queued`, `submitted: true`, conversation `3db2e13a-…`.

## air → mini

- Mini host under `rust-mesh-iroh-peer-mini-host`
- Device `7083e4c4-…`, endpoint `8da958de…`, trust group `b03501fa-…`
- Air client Peer call result:

```
XHOST_AIR_TO_MINI_OK d30dd812-65d2-49bd-a986-39f72b0b1613
```

## Cleanup

Killed only `mesh-iroh-peer` / `rust-mesh-iroh-peer-*` processes started for this smoke. Left pre-existing `peer-phase-a` `pharos-meshd` and other tmux sessions untouched.

## PARTIAL notes

- Proven path is Rust↔Rust Peer `host.runtime.call` → local Runtime `delivery.submit-member` (queued).  
- **NOT-TESTED:** Agy/replyOnce room visibility on the far host (Swift product XHOST path); this stream’s gate is Peer submit-member *equivalent* over Rust mesh.
- **NOT-TESTED:** Bit-identical wire with live Swift MeshReplicaRPC (`success`/`failure` disposition names differ from Phase 0 `response`/`error`).
