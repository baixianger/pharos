# ADR-002: Make the Broker the project-data authority

**Status:** Accepted

**Date:** 2026-07-16

**Decider:** Pai

## Context

Pharos historically stored projects, issues, logs, Trash, and issue attachments
in a local or iCloud Drive data directory. Mesh later made the Broker authoritative
for chat transcripts and attachments, while iOS read a separate `projects.json`
copy from that machine. This produced two synchronization systems and allowed the
Broker copy to drift from the two Macs' matching iCloud registry.

Before this decision, all three stores were archived with SHA-256 manifests. The
two Macs had an identical registry containing 17 projects; that snapshot is the
migration source.

## Decision

- The Broker is the single source of truth for portable data: projects, issues,
  updates, milestones, Trash, rooms, messages, presence metadata, and blobs.
- Registry reads return a SHA-256 content revision. Registry writes are
  compare-and-swap and fail on a stale revision; last-writer-wins is forbidden.
- Before every accepted registry replacement, the Broker creates an atomic
  backup and retains the newest 200 versions.
- macOS and iOS retain local caches for startup and temporary offline reading.
  An offline macOS edit is queued; a conflict preserves the local snapshot in a
  conflict file and reloads the Broker version.
- Checkout paths, SSH routes and keys, tool paths, and tmux runtime state remain
  Host-local. A controller asks the execution Host to resolve its own project
  path instead of reading paths from the Broker registry.
- Existing iCloud data is imported once. iCloud is no longer a live transport or
  a settings choice; its pre-migration directory remains an external backup.
- Tailscale remains the network trust boundary for this personal deployment.
  The Broker still does not execute Host shell commands.

## Options considered

### Keep iCloud plus Broker

Rejected because two authorities require reconciliation rules and leave Linux
and iOS dependent on copied registry files.

### Use unconditional full-snapshot writes

Rejected because two clients can silently erase each other's changes.

### Broker authority with revisioned snapshots

Chosen because the current registry is small, atomic snapshots are easy to back
up and restore, and compare-and-swap gives explicit conflict behavior without
prematurely introducing a database or CRDT.

## Consequences

- The Broker is required for new portable-data writes.
- Clients can read their last cache while offline.
- Concurrent writes may surface an explicit conflict that requires replaying a
  preserved local edit.
- A future multi-user version must add authenticated identities and finer-grained
  mutation APIs before moving beyond the personal Tailscale trust boundary.
