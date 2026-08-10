# ADR-003: Local-first distributed Mesh with partitioned authority

**Status:** Accepted for staged implementation

**Date:** 2026-07-20

**Decider:** Pai

## Context

Pharos currently has one Broker that owns portable data and one TCP endpoint
that every remote client reaches through Tailscale. This is operationally clear,
but it makes a personal multi-device tool depend on a configured network address,
a VPN, and one always-available authority.

The desired product experience is different:

- a Mac or iPhone is paired once by device identity, not by IP address;
- the same relationship works on home Wi-Fi, office Wi-Fi, and cellular data;
- useful data remains available and editable while peers are offline;
- no device can accidentally execute an agent command twice after a partition;
- relay and push infrastructure may improve reachability, but must not own the
  user's projects, conversations, credentials, or agent state.

Iroh is the selected connectivity substrate. It addresses peers by public-key
Endpoint ID, establishes encrypted QUIC connections, attempts direct NAT
traversal, and falls back to encrypted relays. The current stabilized Iroh 1.x
surface has Swift bindings for macOS and iOS. Iroh solves identity-based
connectivity; it does not by itself define Pharos replication or command
semantics.

## Decision

Pharos will become a **local-first distributed device mesh with partitioned
authority**.

It will not become an unrestricted multi-master system. Replicated user data and
side-effecting runtime control have different consistency requirements and use
different rules.

### 1. Device identity and trust group

Each installation owns an Iroh secret key and stable Endpoint ID. Secret keys are
device-local:

- macOS and iOS store them in Keychain;
- headless Linux stores them in a mode-0600 service-owned file, with optional
  system keyring integration later;
- secret keys never enter the replicated event log, pairing payload, APNs
  notification, analytics, or diagnostics.

A user's devices form a trust group. Pairing uses an expiring, single-use,
signed invitation containing the trust-group ID, inviter Endpoint ID/address
ticket, requested roles, and a nonce. Accepting a device is itself a replicated
membership event. Removing a device advances a membership epoch so a removed
key cannot authorize later events merely by replaying an old log.

Human-readable host names are presentation metadata. Endpoint IDs and generated
device IDs are routing identity. Agent session IDs remain ephemeral runtime
identity.

### 2. Connectivity

All remote Mesh traffic uses one versioned ALPN:

```
me.pai.pharos/mesh/1
```

One peer connection multiplexes short request streams, replication streams,
attachment streams, and presence datagrams. Iroh chooses direct or relay paths;
Pharos never stores a public, private, or Tailscale IP as peer identity.

Relay and discovery services are replaceable infrastructure. They route encrypted
traffic and may be public or self-hosted, but do not store authoritative Pharos
state. Local UDS remains the process boundary between the desktop/CLI and a local
runtime. The legacy TCP/Tailscale transport remains available only during staged
migration and rollback.

### 3. Replicated durable data

Every trusted device has a local durable replica backed by SQLite in WAL mode.
The replication primitive is an immutable, signed event envelope:

```
event ID          UUIDv7 (globally unique)
trust group       stable group ID
author            Endpoint ID
author sequence   strictly increasing per author
membership epoch  rejects events from removed devices
hybrid time       wall clock + logical counter for deterministic ordering
entity            type + stable entity ID
operation         versioned operation name
payload           canonical encoded bytes
previous hash     per-author hash chain
signature         author signature over the complete envelope
```

Peers exchange per-author sequence vectors and request missing ranges. Applying
the same event more than once is harmless. Events are retained until every
non-retired trusted replica has acknowledged them and a signed snapshot permits
compaction.

Conflict rules are domain-specific:

- chat messages and updates are immutable append-only values;
- edits and deletions are explicit events, never destructive history rewrites;
- projects and issues use field-level last-writer-wins registers ordered by
  hybrid time, then Endpoint ID as a deterministic tie-break;
- ordered issue lists use explicit fractional/order keys and deterministic
  rebalancing events;
- membership and key revocation require the current membership epoch;
- attachments are content-addressed blobs and fetched lazily;
- presence, typing, connection path, and agent liveness are expiring observations,
  not durable replicated truth.

### 4. Partitioned execution authority

The Host that owns a process, tmux server, checkout, or credential is the sole
authority for that runtime resource. No other peer may merge or infer its state.
Structured agent hooks and direct Host process probes remain authoritative;
terminal text remains non-authoritative.

Commands are directed to one Host Endpoint ID and contain a globally unique
command ID, idempotency key, deadline, expected resource generation, and allowed
action. The Host persists command receipts before execution and returns the same
receipt for retries. A command accepted in one resource generation cannot be
replayed against a later tmux session that reused a display name.

Project/issue mutations replicate normally. Operations that must be serialized
may use a short owner lease with an epoch. Losing quorum or the current owner
produces an explicit unavailable state; Pharos never reports an offline command
as executed.

### 5. Platform responsibilities

**macOS app**

- owns a local replica and local networking runtime;
- exposes connection path, sync health, trusted devices, and revocation UI;
- executes only resources owned by this Mac;
- may act as an optional always-on sync anchor, without becoming a data authority.

**iOS app**

- owns a full metadata/chat replica and lazily cached blobs;
- uses Iroh while foregrounded;
- receives content-free APNs wake hints, then reconnects and syncs encrypted data;
- remains useful from its local replica when background execution is unavailable;
- never sends private keys, project contents, or message text through APNs.

**Mesh CLI and headless Host**

- use the same protocol, event rules, device identity, and command receipts;
- keep script-friendly verbs and machine-readable output;
- expose route and sync diagnostics without exposing key material;
- on Linux, package the cross-platform Iroh runtime with the existing service.

### 6. Implementation boundary

Replication semantics live in a portable Swift `PharosMeshProtocol` module shared
by macOS, iOS, and Linux Swift targets. Iroh integration lives behind a transport
interface. Apple targets use the maintained Iroh Swift bindings. If the Swift
bindings cannot support Linux, the Linux package uses a small Rust Iroh bridge
behind the same local framed protocol rather than forking application semantics.

Higher-level experimental Iroh protocols are not required for the first release.
Pharos initially implements its small trust-group anti-entropy protocol directly
over stable Iroh QUIC streams.

## Consequences

### Benefits

- pairing survives IP, router, and network changes;
- Tailscale and manual Broker endpoint configuration disappear from the normal
  product experience;
- one offline Mac does not make replicated project/chat data unavailable;
- command ownership remains deterministic and auditable;
- public/self-hosted relays and APNs are replaceable reachability services, not
  stores of user truth.

### Costs and risks

- key lifecycle, revocation, event validation, compaction, and conflict UX become
  product responsibilities;
- iOS background delivery is opportunistic even with push;
- clocks are untrusted, so hybrid clocks and deterministic tie-breaks are needed;
- migrations must prevent legacy Broker writes and distributed writes from
  silently diverging;
- Iroh's Apple packaging and Linux path must be proven before removing TCP.

## Rejected alternatives

### Keep a permanent central Broker and only replace TCP with Iroh

This removes IP/Tailscale configuration but retains the single availability and
write-authority bottleneck. It is a useful migration stage, not the end state.

### Make every value unrestricted multi-master

This is attractive for symmetry but unsafe for agent execution, permissions,
session lifecycle, and other side effects. Deterministic conflict resolution does
not make duplicate external actions correct.

### Put authoritative data in a relay or push service

This recreates a central cloud dependency and enlarges the privacy boundary.
Relays and APNs remain transport hints only.

## Supersession and rollback

ADR-001 and ADR-002 remain authoritative while the legacy mode is active. At
distributed cutover, this ADR supersedes their single-Broker data authority and
Tailscale trust-boundary decisions, while preserving their separation between
portable data and Host-local execution.

The pre-change repository state is preserved on
`archive/pre-distributed-iroh-2026-07-20`. Legacy data is never deleted during
migration; rollback selects legacy mode and reopens the untouched Broker store.

