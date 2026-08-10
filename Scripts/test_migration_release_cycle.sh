#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BINARY=${PHAROS_MESH_BINARY:-"$ROOT/.build/debug/pharos-mesh"}
[[ -x "$BINARY" ]] || { echo "error: build pharos-mesh first: swift build --product pharos-mesh" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 is required" >&2; exit 1; }
command -v sqlite3 >/dev/null || { echo "error: sqlite3 is required" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pharos-migration-release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
LEGACY="$WORK/legacy"
REPLICA="$WORK/replica"
EVIDENCE="$WORK/evidence"
GROUP="55555555-5555-4555-8555-555555555555"
PROJECT="11111111-1111-4111-8111-111111111111"
ATTACHMENT="22222222-2222-4222-8222-222222222222"
MESSAGE="44444444-4444-7444-8444-444444444444"
mkdir -p "$LEGACY/mesh/attachments/$ATTACHMENT" "$REPLICA" "$EVIDENCE"

printf '%s' 'verified migration attachment' > "$LEGACY/mesh/attachments/$ATTACHMENT/data"
ATTACHMENT_SHA=$(shasum -a 256 "$LEGACY/mesh/attachments/$ATTACHMENT/data" | awk '{print $1}')
ATTACHMENT_SIZE=$(wc -c < "$LEGACY/mesh/attachments/$ATTACHMENT/data" | tr -d ' ')

cat > "$LEGACY/projects.json" <<EOF
[{"id":"$PROJECT","name":"Release Cycle Fixture","path":"/tmp/example","issues":[{"id":"33333333-3333-4333-8333-333333333333","number":1,"title":"Verify full cutover"},{"id":"33333333-3333-4333-8333-333333333334","number":2,"title":"Verify rollback"}]}]
EOF
cat > "$LEGACY/mesh/release-cycle.jsonl" <<EOF
{"id":"$MESSAGE","from":"agent","room":"release-cycle","text":"migration proof","ts":123,"to":["human"]}
EOF
cat > "$LEGACY/mesh-mailboxes.json" <<EOF
{"version":1,"rooms":{"release-cycle":{"members":{"agent":"member-1","human":"member-2"},"mailboxes":{"member-1":[],"member-2":[{"id":"$MESSAGE","from":"agent","room":"release-cycle","text":"migration proof","ts":123,"to":["human"]}]}}}}
EOF
cat > "$LEGACY/mesh/attachments/$ATTACHMENT/metadata.json" <<EOF
{"id":"$ATTACHMENT","name":"proof.txt","mimeType":"text/plain","byteSize":$ATTACHMENT_SIZE,"sha256":"$ATTACHMENT_SHA"}
EOF

SOURCE_BEFORE=$(cd "$LEGACY" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
tar -C "$WORK" -czf "$WORK/legacy-backup.tgz" legacy
tar -tzf "$WORK/legacy-backup.tgz" >/dev/null

"$BINARY" distributed migration-import \
  --group "$GROUP" --legacy-data-dir "$LEGACY" --data-dir "$REPLICA" --json \
  > "$EVIDENCE/01-import.json"

python3 - "$EVIDENCE/01-import.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["counts"] == {
    "attachments": 1, "issues": 2, "memberships": 2,
    "messages": 1, "projects": 1, "rooms": 1, "unreadMessages": 1,
}, d
assert d["cutover"]["mode"] == "shadow", d
assert d["cutover"]["generation"] == 1, d
assert d["networkState"] == "stopped", d
PY

INVENTORY=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["inventoryDigest"])' "$EVIDENCE/01-import.json")
"$BINARY" distributed migration-status --group "$GROUP" --data-dir "$REPLICA" --json > "$EVIDENCE/02-shadow.json"
"$BINARY" distributed cutover --group "$GROUP" --inventory "$INVENTORY" --generation 1 --data-dir "$REPLICA" --json > "$EVIDENCE/03-cutover.json"
"$BINARY" distributed rollback --group "$GROUP" --inventory "$INVENTORY" --generation 2 --data-dir "$REPLICA" --json > "$EVIDENCE/04-rollback.json"
"$BINARY" distributed cutover --group "$GROUP" --inventory "$INVENTORY" --generation 3 --data-dir "$REPLICA" --json > "$EVIDENCE/05-recutover.json"
"$BINARY" distributed migration-status --group "$GROUP" --data-dir "$REPLICA" --json > "$EVIDENCE/06-final.json"

python3 - "$EVIDENCE" "$INVENTORY" <<'PY'
import base64, json, pathlib, sys
root, digest = pathlib.Path(sys.argv[1]), sys.argv[2]
expected = [
    ("02-shadow.json", "shadow", 1),
    ("03-cutover.json", "distributed", 2),
    ("04-rollback.json", "rolled-back", 3),
    ("05-recutover.json", "distributed", 4),
    ("06-final.json", "distributed", 4),
]
for name, mode, generation in expected:
    d = json.load(open(root / name))
    assert base64.b64decode(d["inventoryDigest"]).hex() == digest, d
    assert d["mode"] == mode and d["generation"] == generation, d
PY

DATABASE="$REPLICA/replica-v1.sqlite"
[[ $(sqlite3 "$DATABASE" 'select count(*) from materialized_immutable_values;') -eq 5 ]]
[[ $(sqlite3 "$DATABASE" "select count(*) from materialized_immutable_values where entity_type='project';") -eq 1 ]]
[[ $(sqlite3 "$DATABASE" "select count(*) from materialized_immutable_values where entity_type='room';") -eq 1 ]]
[[ $(sqlite3 "$DATABASE" "select count(*) from materialized_immutable_values where entity_type='message';") -eq 1 ]]
[[ $(sqlite3 "$DATABASE" "select count(*) from materialized_immutable_values where entity_type='attachment';") -eq 1 ]]
[[ $(find "$REPLICA/replica-v1.sqlite.blobs" -type f | wc -l | tr -d ' ') -eq 1 ]]
cmp "$LEGACY/mesh/attachments/$ATTACHMENT/data" "$(find "$REPLICA/replica-v1.sqlite.blobs" -type f)"

SOURCE_AFTER=$(cd "$LEGACY" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
[[ "$SOURCE_BEFORE" == "$SOURCE_AFTER" ]]

printf 'migration release cycle passed\n'
printf 'inventory=%s\n' "$INVENTORY"
printf 'counts=projects:1 issues:2 rooms:1 messages:1 memberships:2 unread:1 attachments:1\n'
printf 'states=shadow:1 distributed:2 rolledBack:3 distributed:4\n'
printf 'legacy_source_sha256=%s\n' "$SOURCE_AFTER"
printf 'backup=verified\n'
