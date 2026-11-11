#!/usr/bin/env bash
# XHOST Peer delivery.submit-member via Rust mesh (run on CLIENT host).
# Env:
#   DATA_DIR, PEER_ENDPOINT, PEER_ADDR_JSON, HOST_DEVICE_ID, MESH_BIN
set -euo pipefail
DATA_DIR="${DATA_DIR:?}"
PEER_ENDPOINT="${PEER_ENDPOINT:?}"
PEER_ADDR_JSON="${PEER_ADDR_JSON:?}"
HOST_DEVICE_ID="${HOST_DEVICE_ID:?}"
MESH_BIN="${MESH_BIN:?}"
mkdir -p "$DATA_DIR/logs"
REQ="$DATA_DIR/submit-member.json"
cat >"$REQ" <<EOF
{"jsonrpc":"2.0","id":"xhost-1","method":"delivery.submit-member","params":{"memberID":"member-mesh-1","idempotencyKey":"mesh:xhost-smoke:1","payload":"{\"body\":\"xhost-rust-mesh\",\"room\":\"smoke\"}"}}
EOF
RUST_LOG=error "$MESH_BIN" call \
  --data-dir "$DATA_DIR" \
  --peer-endpoint "$PEER_ENDPOINT" \
  --peer-addr "$PEER_ADDR_JSON" \
  --host-device-id "$HOST_DEVICE_ID" \
  --request-file "$REQ" \
  --relay-disabled \
  | tee "$DATA_DIR/logs/peer-call.json"
python3 - <<PY
import json
from pathlib import Path
raw = Path("$DATA_DIR/logs/peer-call.json").read_text()
obj = json.loads(raw[raw.find("{"):])
inner = json.loads(obj["jsonrpcResponse"])
assert inner.get("result",{}).get("submitted") is True, inner
print("XHOST_PEER_CALL_OK", inner["result"].get("deliveryID"))
PY
