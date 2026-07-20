# Distributed Mesh implementation plan

This plan turns ADR-003 into independently verifiable slices. A phase may ship
only when its exit criteria pass on macOS, iOS, and the Mesh CLI surfaces it
affects.

## Product invariants

These are release blockers, not aspirations:

1. A peer is addressed by cryptographic identity, never by a user-entered IP.
2. Removing a device prevents it from authorizing new events after the new
   membership epoch is observed.
3. Applying any event or command receipt twice has the same result as once.
4. Only the owning Host can assert agent lifecycle or execute Host commands.
5. Offline UI distinguishes cached, pending, accepted, executed, and failed.
6. Relay operators and APNs cannot read Pharos payloads.
7. Legacy and distributed stores are never writable at the same time without an
   explicit bridge transaction and audit record.
8. A failed migration has a documented, tested rollback that preserves both
   stores.

## Target component model

```
                   APNs (wake hint only)
                           |
        +------------------+------------------+
        |                                     |
  iPhone / iPad                         Mac controller
  local replica                         local replica
  Iroh endpoint                         Iroh endpoint
        |                                     |
        +---------- direct QUIC or ------------+
                    encrypted relay
                           |
                 trusted Host endpoints
              local replica + command journal
              tmux / agents / local checkouts
```

There is no global data leader. There is a single authority for each Host-owned
runtime resource.

## Phase 0 — preserve and measure the legacy baseline

**State:** complete

- Archive branch: `archive/pre-distributed-iroh-2026-07-20`
- Development branch: `feat/distributed-iroh`
- Record existing unit-test count, package/build commands, data locations, wire
  capabilities, and broker-restart behavior.
- Add fixtures for a representative registry, room history, membership, unread
  mailbox, node command, and attachment manifest.

Exit: legacy tests pass from the development branch and the archive branch can
be checked out without moving or deleting user data.

## Phase 1 — shared protocol and transport seam

**State:** complete

Implemented on `feat/distributed-iroh`:

- transport-neutral request/response bytes and explicit legacy/Iroh preferences;
- shared identity, UUIDv7 event, hybrid-time, entity/operation, Host command,
  and durable receipt value types;
- deterministic signing bytes, Ed25519 verification, SHA-256 author hash chains,
  size/generation/deadline validation, and receipt transition rules;
- canonical legacy request/response/event/message models shared by macOS, iOS,
  and CLI, with byte-for-byte request and response fixtures plus tolerant legacy
  message decoding;
- UDS/TCP and iOS `NWConnection` legacy adapters behind `MeshTransport`, including
  framed attachment bodies, bounded socket I/O, and isolated temporary-UDS tests;
- explicit `legacy | iroh | automatic` selection where Phase 1 rejects a required
  Iroh route and keeps automatic mode on the legacy rollback path;
- Linux arm64 compile proof with the official `swift:6.2-jammy` image and a
  read-only repository mount:

  ```sh
  docker run --rm --platform linux/arm64 -v "$PWD:/workspace:ro" -w /workspace \
    swift:6.2-jammy swift build --target PharosMeshProtocol \
    --scratch-path /tmp/pharos-build
  ```

  Verified image digest: `sha256:1c1f422aee767a7f33b88bc3aee99cad5de4af8723fbee8a3ab6951a6879f929`.

1. Create a pure Swift `PharosMeshProtocol` target with no AppKit, UIKit,
   Network.framework, socket, filesystem, or process dependencies.
2. Move/canonicalize shared wire value types currently duplicated by macOS and
   iOS. Preserve encoded field names and add golden JSON compatibility tests.
3. Define transport-neutral framed request, response, event, and blob headers.
4. Put the current UDS/TCP implementation behind `MeshTransport`; keep legacy
   behavior as the default.
5. Add an explicit `legacy | iroh | automatic` transport preference, but reject
   `iroh` with a clear unsupported error until Phase 2 is present.

Exit: macOS, iOS, CLI, and Linux compile against the shared protocol; current
wire fixtures remain byte-compatible; no runtime behavior changes in legacy
mode.

## Phase 2 — identity, pairing, and Iroh connectivity

**State:** started (Iroh transport, durable identity primitives, trust-group
pairing, and authenticated replica RPC routing present; product endpoint
lifecycle, CLI diagnostics, revocation UI, and Trusted Devices UI remain pending)

Implemented on `feat/distributed-iroh`:

- exact SwiftPM pin to the official `n0-computer/iroh-ffi` `v1.1.0` release;
- release provenance, license, Apple slice, and Linux artifact checks recorded in
  [IROH-DEPENDENCY.md](IROH-DEPENDENCY.md);
- `PharosMeshIroh` endpoint runtime using the production `me.pai.pharos/mesh/1`
  ALPN, opaque Endpoint IDs, cached peer connections, direct/relay path
  classification, and bounded binary request/response streams;
- relay-disabled loopback tests bind fresh identities to independent ephemeral
  `127.0.0.1:0` ports and prove a framed request/attachment response plus stable
  Endpoint ID restoration from the same secret key. A deliberately stalled
  stream proves the public timeout returns in under one second rather than
  waiting for the underlying FFI operation to unwind;
- `MeshReplicaRPCServer` authorizes the remote Endpoint ID reported by the Iroh
  QUIC connection against an exact current-epoch trust row before routing any
  application operation. A relay-disabled isolated Iroh test proves the router
  does not trust an Endpoint ID supplied in request JSON;
- iOS XcodeGen consumes the same `PharosMeshIroh` product. Non-Apple builds see
  an explicit unavailable implementation until the pinned Linux bridge is wired;
- `PharosMeshIdentity` owns one Ed25519 secret whose public key is proven to be
  the Iroh Endpoint ID. Apple storage uses a non-synchronizing,
  device-only Keychain item; Linux/headless storage uses an atomic mode-0600 file
  in a mode-0700 directory, rejects symlinks and permissive paths, and survives
  concurrent first launch without rotating identity;
- signed pairing tickets use canonical bytes, a maximum ten-minute lifetime,
  32-byte bearer nonces, explicit roles, trust-group membership epochs, and
  redacted descriptions. Invitation and acceptance signatures bind Endpoint IDs
  to signing keys, and tamper/expiry/key-mismatch tests fail closed;
- SQLite schema v2 stores only pending invitation/nonce digests, atomically burns
  a ticket in the same transaction that persists the trusted device, waits for
  competing writers, and revokes pending tickets when the membership epoch
  advances. Tests prove one winner across sixteen actor tasks and eight separate
  SQLite connections, persistence across reopen, v1-to-v2 state preservation,
  and future-schema rejection;
- the iOS project consumes `PharosMeshIdentity` and the portable
  `PharosMeshReplica` product; isolated simulator builds compile and link
  Keychain, identity, pairing, Crypto, SQLite, replica persistence, and Iroh for
  both arm64 and x86_64. The identity and replica targets compile in the official
  Swift 6.2 Linux arm64 image. These checks use disposable copies/scratch paths
  and fresh identities; no production Keychain item, database, Broker, room, or
  endpoint is opened.

1. Pin a reviewed Iroh 1.x / iroh-ffi release; verify license, binary provenance,
   reproducible XCFramework build, and macOS/iOS architectures.
2. Implement device-key stores for macOS Keychain, iOS Keychain, and Linux
   mode-0600 storage.
3. Implement `me.pai.pharos/mesh/1` endpoint lifecycle and a connection manager
   with direct/relay path observation.
4. Replace Broker pairing QR data with signed, expiring, single-use trust-group
   invitations. Prevent screenshots/logs from exposing invitation secrets.
5. Add CLI commands:

   ```text
   pharos device id
   pharos device invite [--role controller|host|replica]
   pharos device accept <ticket>
   pharos device list
   pharos device revoke <device-id>
   pharos mesh doctor --json
   ```

6. Add macOS/iOS Trusted Devices UI and show direct, relay, reconnecting, and
   offline path state without surfacing IP addresses as identity.

Exit: two Macs on unrelated NATs and one iPhone on cellular pair once and
reconnect by Endpoint ID; direct and forced-relay tests pass; revocation blocks a
new connection; legacy mode still works.

## Phase 3 — local event store and anti-entropy sync

**State:** started (durable sync/materialization and portable local-replica
wiring present; authenticated network routing remains pending)

The isolated `DistributedMeshStore` now creates a caller-selected SQLite WAL
replica with the Phase 3 tables. It verifies signatures, membership epoch,
per-author sequence continuity, and previous hashes transactionally; duplicate
events are idempotent. It also persists Host command acceptance before side
effects, rejects semantic idempotency-key collisions, and prevents terminal
receipt replay. Current tests create databases only under a fresh system
temporary directory and never open the live Broker or Mesh data locations.

Schema v2 is a transactional migration over v1, preserves existing rows,
rejects ambiguous/future metadata, and adds atomic pairing-use/trusted-device
tables. Schema v3 adds field registers and a durable derived-state version;
schema v4 adds independently stamped immutable values so derived state no longer
depends on retaining source-event rows. Schema v5 adds content-addressed blob
manifests, local transfer state, and resumable per-chunk receipts with database
constraints and cascading cleanup. A v2/v3/v4 upgrade, or a process death
between schema creation and replay, rebuilds materialized state from the retained
event log and latest verified snapshot on first use. SQLite is exposed
through the explicit `CSQLite` SwiftPM system-library target instead of an
Apple-only implicit module. With `libsqlite3-dev` installed, `PharosMeshCore`
compiles in the official `swift:6.2-jammy` Linux arm64 image.

The transport-neutral sync foundation now includes canonical per-author vectors,
bounded missing-range requests, bounded event batches, and monotonic durable peer
acknowledgements that cannot advance beyond the local head. A hybrid logical
clock handles wall-clock regression, remote observations, logical overflow, and
terminal overflow without trapping. Project/issue fields materialize as LWW
registers ordered by HLC, Endpoint ID, and a final event-ID tie-break; explicit
tombstones remain visible. Immutable values resolve ID collisions deterministically.
Malformed payloads for known operations remain in the signed event chain for
forward compatibility but enter semantic quarantine and never reach derived
state. Tests exercise three replicas with different inter-author arrival orders.

Replica snapshots contain canonical field/immutable state, per-author sequence
and hash checkpoints, a state digest, creator identity, membership epoch, and an
Ed25519 signature. Snapshot IDs are immutable; every database read re-verifies
the digest, Endpoint-ID/key binding, and signature. Installation atomically
restores state and author heads without deleting local history. Compaction is a
separate transaction that requires an already-persisted snapshot and a monotonic
acknowledgement from every caller-supplied active peer for every checkpoint.
After compaction, a range request receives the covering snapshot explicitly
instead of an empty/misleading event batch, and new events continue the retained
author-head hash chain. Production wiring must derive the active-peer set from
the revocation-aware membership view; callers cannot enable this API yet.

Attachments now use transport-neutral SHA-256 manifests and bounded chunks.
The store accepts chunks out of order across independent SQLite connections,
deduplicates retry delivery, verifies each chunk before recording it, and only
atomically publishes a final mode-0600 file after its byte count and whole-blob
digest match. Missing/corrupt chunk files are rediscovered after restart;
whole-blob corruption clears receipts for a safe re-fetch. Finalization is
idempotent, eviction removes final and partial cache state while retaining the
manifest for lazy fetch, and storage refuses symbolic-link traversal. Isolated
tests cover tampered chunks, wrong final content, restart recovery, concurrent
connection handoff, eviction/re-fetch, and chunk/final symlink attacks.

The persistence and signing layer now lives in the transport-independent
`PharosMeshReplica` product, which is shared by macOS, iOS, and the Mesh CLI.
`MeshLocalReplica` opens the same schema and stable device identity on every
surface. Apple platforms use Application Support plus a device-only Keychain
identity; Linux uses the XDG data directory (or `~/.local/share`) plus a
mode-0600 file identity. Replica directories are mode 0700, SQLite files are
mode 0600, and symbolic-link roots/databases fail closed.

macOS and iOS open their local replica during app startup without dialing a
peer. The CLI exposes `pharos-mesh distributed status|init`; its
`--data-dir ABSOLUTE-PATH` mode keeps identity and SQLite state entirely under a
caller-selected disposable directory. Status reports protocol/schema, device
and Endpoint IDs, database path, and `network=stopped`. This is persistence
wiring only: it does not read, start, stop, or modify the legacy Broker and does
not automatically start Iroh networking.

The transport-neutral `MeshReplicaRPCHeader` correlates every request and
response by UUID, operation, trust group, membership epoch, and disposition.
Typed payloads use the bounded transport body; only small routing/chunk metadata
enters the header. `MeshReplicaRPCClient` and `MeshReplicaRPCServer` implement
vector exchange, bounded range/snapshot fetch, monotonic acknowledgement,
manifest lookup, verified chunk fetch, and directed Host commands. The Host
client checks command correlation, semantic fingerprint, target identity, and
the Host's Ed25519 receipt signature before returning a receipt.

`MeshReplicaSyncSession` performs a bounded pull-and-ack pass, reusing the
store's signature, membership, sequence, hash-chain, snapshot, and
materialization checks. Both peers run the same pass for bidirectional
anti-entropy. Isolated tests cover event convergence, bounded blob reconstruction,
Host command receipt routing, response-ID mismatch, unknown Endpoint IDs, and
membership-epoch revocation without opening production state.

Product endpoint scheduling, richer room/message/project/issue operation
adapters, revocation-aware compaction policy, streaming snapshots larger than a
single bounded RPC body, and the randomized partition/reordering simulation
remain pending.

1. Add SQLite/WAL schema for events, author heads, materialized entities, blob
   manifests, peer acknowledgements, membership epochs, and snapshots.
2. Implement canonical event encoding, signatures, per-author sequence/hash
   validation, hybrid logical clocks, and quarantine for invalid events.
3. Implement vector exchange and bounded missing-range requests over Iroh.
4. Materialize rooms, messages, projects, issues, updates, and Trash using the
   conflict rules in ADR-003.
5. Store attachments by digest; transfer in bounded chunks; verify digest before
   publication; support lazy fetch and cache eviction.
6. Add deterministic simulation tests for reordering, duplication, partitions,
   clock skew, revocation, compaction, and three-way convergence.

Exit: three replicas converge byte-for-byte after random partitions and event
reordering; offline edits remain visible locally and sync after reconnect;
corrupt or unauthorized events never enter materialized state.

## Phase 4 — Host authority and distributed commands

**State:** started (authenticated Host-local authority and exactly-once claim
foundation complete; shared local replica surfaces are present, while command
lifecycle adapters remain pending)

Implemented on `feat/distributed-iroh`:

- schema v6 keeps the legacy v1 receipt table as a rollback journal and adds
  Host-local resource authority plus a separate authenticated receipt journal;
- resources bind trust group, Host device ID, Endpoint ID, allowed actions, and
  a store-owned generation; explicit replacement atomically advances the
  generation while an app restart alone does not;
- controller commands carry membership epoch and sender Endpoint ID in an
  Ed25519-signed directed envelope; acceptance verifies current paired-device
  membership, controller role, target Host identity, deadline, action, and
  persisted generation;
- accepted, rejected, and expired decisions are Host-signed receipts. An atomic
  accepted-to-executing claim returns `shouldExecute=true` to exactly one SQLite
  contender; retries, reconnects, and restart recovery return the same receipt
  with `shouldExecute=false`;
- tests cover signature tampering, unknown senders, wrong Host Endpoint ID,
  revoked membership epoch, stale generation, disallowed actions, expiration,
  concurrent claims, crash recovery, terminal replay, and signed receipt
  verification without contacting a running Mesh.
- the authenticated replica RPC command route binds the QUIC peer Endpoint ID
  to the signed controller envelope and returns only a correlated,
  signature-verified Host receipt; it still never performs the side effect.

1. Bind each Host profile to a trusted device ID and Endpoint ID.
2. Persist a local Host resource generation for every agent/tmux session.
3. Implement directed command envelopes and a durable receipt journal.
4. Require expected resource generation for poke/stop/attach-sensitive actions.
5. Preserve structured-hook lifecycle authority and node liveness probes.
6. Make retries idempotent across connection loss, app restart, and relay path
   migration.
7. Keep SSH as an explicit bootstrap/recovery feature during this phase; remove
   it from routine Mesh delivery.

Exit: fault injection cannot produce duplicate spawn/stop effects; a stale
command cannot target a replacement session; UI and CLI display accepted versus
executed truthfully.

## Phase 5 — iOS background wake and offline UX

1. Register APNs device tokens as encrypted trust-group metadata visible only to
   authorized peers or an opt-in push gateway.
2. Push payload contains only a random collapse/topic token and event-available
   hint; never names, text, project IDs, Endpoint IDs, or keys.
3. On wake/foreground, iOS opens Iroh, runs bounded sync, updates local
   notifications, and closes according to system budget.
4. Show last-sync time and pending operations. Queue safe data edits; require an
   online owner for side-effecting Host commands.
5. Test disabled notifications, delayed/coalesced pushes, force quit, Low Power
   Mode, cellular-only, and relay-only paths.

Exit: the app remains useful with no background grant and converges on next
foreground; push improves freshness without becoming correctness-critical.

## Phase 6 — migration and cutover

1. Export a signed legacy snapshot plus blob manifest and SHA-256 inventory.
2. Import it as a deterministic genesis snapshot into a new trust group.
3. Run a read-only shadow replica and compare materialized views with the Broker.
4. Freeze legacy writes, capture the final delta, verify counts/digests, then
   atomically select distributed mode for the trust group.
5. Retain the legacy store and endpoint settings read-only for at least one full
   release cycle. Provide a one-command rollback before any cleanup.
6. Remove Tailscale/IP setup from normal onboarding only after the migration and
   rollback drills pass on both Macs and iOS.

Exit: a production-shaped snapshot migrates with matching projects, issues,
rooms, messages, memberships, unread markers, and attachments; rollback and
re-cutover are both demonstrated.

## Phase 7 — hardening and removal of legacy transport

- Threat-model malicious paired devices, stolen backups, invitation replay,
  relay observation, event floods, blob bombs, and command replay.
- Add per-peer quotas, stream limits, maximum frame/blob sizes, backpressure,
  structured privacy-safe logs, and key rotation/recovery.
- Ship self-hosted relay documentation without requiring it for ordinary use.
- Remove TCP/Tailscale code only after telemetry-free local diagnostics and user
  migration evidence show no remaining legacy dependency.

## Verification matrix

| Area | Required proof |
|---|---|
| Protocol | Golden fixtures decode on macOS, iOS, and Linux; unknown fields survive versioning policy |
| Convergence | Property tests with duplicates, reordered events, partitions, and clock skew |
| Security | Signature, membership epoch, revocation, replay, size-limit, and malformed-frame tests |
| Connectivity | LAN direct, cross-NAT direct, forced relay, Wi-Fi/cellular switch, reconnect after sleep |
| Commands | Crash before/after receipt persistence, retry, stale generation, duplicated delivery |
| Storage | WAL recovery, snapshot/compaction interruption, blob checksum failure, disk-full behavior |
| Migration | Inventory/digest equality, interrupted import, rollback, repeated dry run |
| UX | Offline/cache labels, pending state, unavailable Host, revoked device, relay diagnostics |

## Decisions deliberately deferred

- Whether a future optional hosted service stores encrypted offline envelopes.
  The first design requires at least one reachable trusted replica for sync.
- Whether to adopt `iroh-gossip` or another higher-level protocol after its FFI
  and wire stability match the core Iroh 1.x surface.
- Multi-user/shared-team authorization. The first trust-group model is for one
  person and their devices, while keeping signed authorship and membership
  epochs extensible.
