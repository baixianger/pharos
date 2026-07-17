# ADR-001: Separate the Mesh Broker from execution Hosts

**Status:** Accepted, extended by the Host node section below

**Date:** 2026-07-16

**Decider:** Pai

## Context

Pharos originally paired two Macs and let one of them implicitly host the Mesh.
Linux headless support later added a direct Broker endpoint, while remote agent
launch continued to use the same single `peerHost` value. The UI could therefore
show a stale Mac-hub toggle beside an active headless endpoint, and “pairing”
incorrectly implied that an execution machine also had to host chat.

## Decision

Broker configuration and execution Hosts are independent:

- The **Broker** owns rooms, messages, attachments, presence, unread state, and
  the opaque project registry served to clients. It never executes shell input.
- A **Host** runs coding agents and a user-scoped `pharos-mesh node`. macOS and
  iOS use SSH only for explicit launch, attach, and stop actions. Routine Poke
  delivery goes Broker → Host node → locally owned tmux.
- This Mac may be the Broker, or every client may dial one explicit remote
  Tailscale endpoint. Selecting a remote Broker clears the obsolete Mac-hub role.
- SSH remains the bootstrap and recovery channel. `pharos mesh node` replaces
  routine Poke operations with an outbound Broker event subscription; the
  Broker itself still does not become a shell executor.

## Options considered

### Keep one paired Mac

Simple, but cannot represent Linux Broker plus several execution machines and
continues to overload one setting with transport, storage, and execution roles.

### Let the Broker execute commands

Convenient superficially, but expands a chat/storage service into a remote-code
execution service, increases its privilege requirements, and makes a compromised
Broker equivalent to compromising every Host. Rejected.

### Separate Broker and Hosts

Adds an explicit Host list and migration work, but gives each component one
security boundary and supports any mix of macOS, iOS, and Linux clients.

## Consequences

- macOS Settings presents Mesh Broker first and Hosts second.
- iOS uses the same vocabulary and keeps SSH private keys only in device Keychain.
- `pharos-mesh` on Linux remains a portable Broker/client CLI and systemd service;
  it does not need AppKit or the macOS launcher.
- The Broker also owns portable project data under ADR-002; execution checkout
  paths and credentials remain local to each Host.
- Host profiles retain SSH routes for explicit remote-control actions; they are
  not part of message delivery.
- Multi-Host routing must match a Broker-reported Host identity; it may fall back
  automatically only when exactly one remote Host exists.

## Host node extension — 2026-07-17

The portable CLI now has a per-user node mode for macOS and Linux execution
Hosts. The Broker publishes typed events rather than shell strings. A node may
only perform the built-in mailbox Poke after matching the target Host and
revalidating the recorded tmux socket, pane, process tree, and idle composer.
Client apps have no Poke fallback. If the Host node is offline, delivery remains
durable in the Broker mailbox and the node recovers unread directed messages
when it reconnects.
