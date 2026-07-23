# Legacy migration release-cycle drill

Verified on 2026-07-21 with an isolated, production-shaped fixture. No live
Pharos directory, identity, Broker, or relay was read or modified.

## Reproduce

```sh
swift build --product pharos-mesh
Scripts/test_migration_release_cycle.sh
```

The script creates a private temporary legacy store, makes and validates a
compressed backup, imports into a fresh local-first replica with networking
stopped, cuts over, rolls back, cuts over again, and deletes the temporary
fixture on exit. It is also an enforced macOS CI step.

## Coverage and acceptance checks

The legacy fixture contains one project, two issues, one room, one transcript
message, two memberships, one unread delivery, and one checksum-verified
attachment with its metadata and bytes. The drill verifies:

- the exact import counts and inventory digest;
- `shadow` generation 1, `distributed` generation 2, `rolled-back` generation
  3, then `distributed` generation 4;
- exactly one write authority in each mode;
- five materialized immutable entities and the preserved attachment bytes;
- an intact, readable pre-import archive;
- an identical source-tree digest before and after the full cycle.

## Recorded result

The 2026-07-21 run completed successfully:

```text
migration release cycle passed
inventory=29e209c94557476cca2dc25aff95d1e02121fae76a2ed94f0c231c0a9d1bb066
counts=projects:1 issues:2 rooms:1 messages:1 memberships:2 unread:1 attachments:1
states=shadow:1 distributed:2 rolledBack:3 distributed:4
backup=verified
```

The source digest is intentionally checked within the run rather than treated
as a release constant. Any fixture-content change must still preserve equality
between the before and after digests.

## Operational boundary

This drill proves the migration artifact, authority-state machine, rollback,
re-cutover, and retention behavior. A real user's cutover still requires an
operator-controlled legacy write freeze and a live read-only shadow comparison
before selecting distributed authority. The legacy store must remain read-only
and backed up for at least one release cycle.
