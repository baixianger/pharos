# Iroh capability adoption for MeshKit and Pharos

**Status:** Accepted roadmap for Mesh 2.0 hardening

**Date:** 2026-07-22

This review maps the current Iroh 1.x architecture and official guidance onto
the public `MeshKit` package and Pharos. It supplements
[ADR-003](ADR-003-LOCAL-FIRST-DISTRIBUTED-MESH.md); it does not replace Pharos'
signed event log, trust-group rules, or partitioned Host authority.

## Decision principles

1. An Iroh Endpoint ID is durable device routing identity. An IP address,
   hostname, display name, and address ticket are not identity.
2. Keep one long-lived Iroh endpoint per app process and route independent,
   versioned protocols by ALPN.
3. Tickets bootstrap pairing or an immediately available route. Long-lived peer
   records persist the Endpoint ID and resolve fresh dialing details through
   discovery.
4. QUIC streams carry durable or ordered application data. Datagrams and Gossip
   may carry expiring observations or invalidation hints only.
5. Gossip can reduce synchronization latency, but the signed event store and
   anti-entropy pull remain the source of truth.
6. Relays, discovery, push notifications, and diagnostics are replaceable
   infrastructure. None may become an authority for user data or device trust.
7. MeshKit exposes transport mechanisms and policy hooks. Pharos owns
   authorization, replication, conflict resolution, and product semantics.

## Adoption matrix

| Iroh capability or practice | MeshKit today | Pharos today | Decision | Target and proof |
| --- | --- | --- | --- | --- |
| Persistent Endpoint ID | Stable secret-key restoration | Endpoint ID is bound to the device signing key | **Keep** | Key restoration and mismatch tests on macOS, iOS, and Linux |
| One Endpoint, multiple ALPN protocols | One endpoint handles one ALPN | One `mesh/1` ALPN carries RPC | **Adopt now** | Add a router-style endpoint API; prove two handlers share one identity and lifecycle |
| Endpoint-ID-only dialing through address lookup | Available in MeshKit 0.2 with an optional ticket hint | Trusted rows persist both ID and the latest ticket; transport can now fall back to ID-only dialing | **Adopt now** | Prefer a fresh hint, then discovery; add reconnect-after-stale-hint device tests |
| Short-lived bootstrap tickets | Typed endpoint ticket | Signed, expiring, single-use Pharos pairing invitation wraps an Iroh ticket | **Keep and clarify** | Redact tickets, show their IP/privacy implications, never treat the Iroh ticket itself as single-use |
| Live path and endpoint observation | MeshKit 0.2 exposes privacy-safe snapshots and a bounded async status stream | CLI/UI expose limited current path state | **Adopt now** | Consume the stream in UI/doctor; add home-relay and network-change events after the FFI watcher is safe |
| Configurable discovery | Uses the upstream production preset or isolated bind | Depends on the same preset | **Adopt next** | Public DNS/DHT/local/custom discovery policy; isolated and no-global-discovery tests |
| Configurable relays | Production, custom/self-hosted, or disabled | Adapter supports all three; product UI exposes production/disabled | **Adopt now** | Add product self-hosted mode and forced-relay integration test; relay-only remains a separate upstream requirement |
| Pre-handler peer authorization | MeshKit 0.2 admission closure rejects before request handling | Adapter exposes it; RPC still checks current trust epoch per operation | **Adopt now** | Wire it for normal sync serving while retaining a distinct pairing admission path |
| QUIC bidirectional streams | One bounded request/response stream | RPC and chunk fetches use the bounded exchange | **Keep** | Retain for commands and anti-entropy; add cancellation and concurrency limits |
| QUIC unidirectional streams | Not exposed | Not used | **Adopt next** | Streaming attachment transfer and progress without buffering the entire body |
| QUIC datagrams | Not exposed | Presence is designed but not shipped | **Experimental** | Presence/typing/path hints only, with expiry, size limit, dedupe, and loss tolerance |
| Gossip topics | Not exposed by the current Swift FFI package | Not used | **Experimental after bindings** | Signed event-ID/head-vector hints trigger an authoritative pull; duplicate and partition tests required |
| iroh-blobs | Not exposed by the current Swift FFI package | SHA-256 content-addressed chunk manifests with resume | **Defer direct adoption** | Borrow verified streaming, ranges, dedupe, and resume now; reconsider when stable Swift bindings exist |
| iroh-docs | Not exposed by the current Swift FFI package | Purpose-built signed events, LWW fields, immutable chat, membership epochs | **Do not replace current store** | Borrow range reconciliation and protocol composition; keep domain-specific trust/conflict semantics |
| Connection and endpoint diagnostics | FFI has stats/path/network watchers; MeshKit does not wrap them | `mesh doctor` has product checks | **Adopt now** | Privacy-safe structured snapshot plus opt-in detailed export; add reconnect/path metrics |
| Resource controls and backpressure | Fixed frame bound and timeout | Bounded RPC/event batches | **Adopt now** | Public stream/body/concurrency limits, cancellation, and peer quotas; adversarial slow-peer tests |
| Swappable transports such as Tor/Bluetooth | Not exposed by current Swift FFI | Not required for Mesh 2.0 | **Defer** | Preserve transport interfaces; adopt only for a concrete product/privacy requirement |
| 0-RTT or replayable early data | Not exposed | Commands have persisted receipts and idempotency keys | **Do not use for mutations** | Any future early data is limited to idempotent reads or hints |

## Layered target

```text
Pharos product semantics
  signed events | membership epochs | anti-entropy | Host command receipts
                 | optional Gossip invalidation hints
MeshKit protocols
  mesh RPC/1 | live hints/1 | blob stream/1 | application-defined ALPNs
MeshKit endpoint
  one identity | router | admission policy | diagnostics | discovery/relay policy
Iroh
  Endpoint ID | QUIC/TLS | NAT traversal | direct paths | encrypted relay fallback
```

The single endpoint is shared; protocol connections remain independent. We do
not require one permanent QUIC connection to carry every kind of traffic.
Independent ALPNs let each protocol version, authorize, limit, and evolve its
wire format without coupling it to the durable replica RPC.

## MeshKit roadmap

### M1 — stable identity and observable connectivity

- Accept either an Endpoint ID or an endpoint ticket when dialing. A ticket is
  an optional fresh route hint, not required persisted state.
- Publish privacy-safe endpoint and peer status values and an `AsyncStream` of
  path/network changes.
- Expose bounded diagnostics: connection path, RTT, reconnect attempts, stream
  counts, last error category, and selected relay mode.
- Make custom relay maps and relay-only/disabled policy public.
- Add an admission policy receiving the authenticated remote Endpoint ID before
  invoking an application protocol handler.

Exit: ID-only reconnect works after a peer changes network; direct, forced-relay,
disabled-relay, unauthorized-peer, and network-change tests pass.

### M2 — one endpoint, composable protocols

- Add a router that registers multiple unique ALPN/handler pairs before start.
- Share one endpoint identity, discovery state, and shutdown lifecycle.
- Reject duplicate ALPNs and changes after startup.
- Keep the current single-protocol `IrohEndpoint` API as a compatibility facade.

Exit: two protocols exchange concurrently through one endpoint while one
protocol's rejection or failure cannot consume the other's traffic.

### M3 — streaming and flow control

- Expose bounded uni- and bidirectional stream primitives with cancellation,
  reset, progress, deadlines, and explicit end-of-stream.
- Add per-peer concurrency and byte quotas plus application backpressure.
- Keep the current whole-frame exchange for small RPC messages.

Exit: large transfers do not require whole-body buffering; cancellation releases
resources; slow peers cannot starve unrelated peers.

### M4 — optional protocol packages

- Prototype `MeshKitGossip` only after stable iroh-gossip Swift bindings exist.
- Consider `MeshKitBlobs` as a separate product rather than growing the core
  transport API.
- Keep protocol packages optional so Linux and Apple support can advance without
  forcing all applications to ship every protocol.

## Pharos roadmap

### P1 — routing lifecycle and operator visibility

- Persist Endpoint IDs as peer identity and treat saved tickets as a replaceable
  cache. Prefer a fresh signed ticket when available, then fall back to discovery.
- Refresh routing hints after authenticated contact without allowing a relayed
  peer to rebind another device.
- Drive Trusted Devices and doctor output from MeshKit's status stream. Normal UI
  shows direct, relay, reconnecting, and offline without IP addresses.
- Add explicit public-relay, self-hosted-relay, and isolated-LAN product modes.

### P2 — fast live notification without a second truth

- Define a signed, versioned hint containing trust-group ID, sender Endpoint ID,
  membership epoch, latest per-author head/vector digest, expiry, and nonce.
- Publish hints to a trust-group Gossip topic when a durable event commits.
- On receipt, deduplicate and schedule the existing bounded anti-entropy pull.
- Never materialize product state from a Gossip payload. Missed, duplicated, or
  reordered hints remain correct because ordinary anti-entropy still converges.
- APNs remains a content-free mobile wake hint and follows the same pull path.

### P3 — attachment transport

- Keep content addressing, manifests, digest verification, lazy fetch, and
  resumable receipts independent from the wire transport.
- Move chunk bodies to bounded streaming when MeshKit M3 is stable.
- Re-evaluate iroh-blobs only if its Swift API is stable across macOS, iOS, and
  Linux and migration preserves existing attachment identifiers.

### P4 — hardening and scale

- Add connection churn, stale-ticket, relay outage, duplicate-Gossip, delayed
  membership transition, slow-peer, and large-blob chaos cases.
- Limit synchronization work per peer and prioritize membership/revocation before
  ordinary events, attachments, and ephemeral hints.
- Record protocol versions and capability negotiation so a Mesh 2.x device can
  fail clearly or downgrade safely rather than infer behavior from app version.

## Explicit non-goals

- Gossip is not a database, ordered log, membership authority, or delivery
  acknowledgement.
- Tickets are not durable peer identity and the embedded Iroh ticket is not an
  application revocation mechanism.
- Relay reachability does not grant trust; TLS Endpoint ID authentication plus
  the current membership epoch grants admission.
- Hostnames and computer names remain editable labels and search aliases only.
- Iroh Documents will not replace Pharos' signed domain model merely to reduce
  custom code.
- Durable chat, project updates, device revocation, and Host commands will not use
  unreliable datagrams.

## First implementation slice

The first code slice is intentionally limited to features already exposed by the
pinned iroh-ffi 1.1.x Swift API:

1. MeshKit Endpoint-ID-only dialing with optional ticket hints.
2. MeshKit privacy-safe status snapshots and path/network observation.
3. MeshKit admission policy and configurable resource limits.
4. Pharos peer routing updated to prefer stable IDs and consume status events.

Multi-ALPN routing follows once this surface is stable. Gossip, iroh-blobs, and
iroh-docs remain separate experiments because the currently pinned Swift package
does not expose their complete protocol APIs.

### Binding limitation discovered during implementation

The generated Swift API exposes `Connection.watchPaths`, but calling it from the
Swift side of iroh-ffi 1.1.1 currently panics because the synchronous binding
starts the watcher without an active Tokio reactor. MeshKit must not wrap a
panic-prone API. Its initial `AsyncStream` status surface therefore uses bounded,
deduplicated snapshots; native callback adoption is gated on an upstream binding
whose watcher lifecycle is runtime-safe and covered by an Apple integration test.

## Official references

- [What is Iroh?](https://docs.iroh.computer/what-is-iroh)
- [Endpoints and what to persist](https://docs.iroh.computer/concepts/endpoints)
- [Tickets and their security properties](https://docs.iroh.computer/concepts/tickets)
- [Using QUIC](https://docs.iroh.computer/protocols/using-quic)
- [Gossip broadcast](https://docs.iroh.computer/connecting/gossip)
- [Blobs](https://docs.iroh.computer/protocols/blobs)
- [Documents](https://docs.iroh.computer/protocols/documents)
- [Security and privacy](https://docs.iroh.computer/deployment/security-privacy)
- [Troubleshooting](https://docs.iroh.computer/troubleshooting)
