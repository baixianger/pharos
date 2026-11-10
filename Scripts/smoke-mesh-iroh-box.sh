#!/usr/bin/env bash
# Box headless mesh + Runtime Peer delivery.submit-member smoke (msg-test only).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$HOME/.cargo/env"
DATA="${PHAROS_MESH_SMOKE_DIR:-/home/box/personal/pharos-msg-test/rust-mesh-iroh-box}"
BIN="$ROOT/rust/target/debug"
MESH="$BIN/pharos-mesh-node"
MESHD="$BIN/pharos-meshd"

rm -rf "$DATA"
mkdir -p "$DATA"/{host,client,runtime-host,logs}
cd "$ROOT/rust"
cargo build -q -p pharos-mesh -p pharos-agent-runtime

# Host Runtime on non-default socket / data-dir.
RUNTIME_SOCK="$DATA/runtime-host/agent.sock"
"$MESHD" --socket "$RUNTIME_SOCK" --data-dir "$DATA/runtime-host" >"$DATA/logs/meshd.log" 2>&1 &
MESHD_PID=$!
HOST_MESH_PID=""
cleanup() {
  [[ -n "${HOST_MESH_PID:-}" ]] && kill "$HOST_MESH_PID" 2>/dev/null || true
  kill "$MESHD_PID" 2>/dev/null || true
  wait "$MESHD_PID" 2>/dev/null || true
  [[ -n "${HOST_MESH_PID:-}" ]] && wait "$HOST_MESH_PID" 2>/dev/null || true
}
trap cleanup EXIT
sleep 0.4

rpc() {
  local line="$1"
  local out="$2"
  python3 - "$RUNTIME_SOCK" "$line" "$out" <<'PY'
import socket, sys
sock_path, line, out = sys.argv[1], sys.argv[2], sys.argv[3]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(sock_path)
s.sendall((line if line.endswith("\n") else line + "\n").encode())
buf = b""
while b"\n" not in buf:
    chunk = s.recv(4096)
    if not chunk:
        break
    buf += chunk
s.close()
open(out, "wb").write(buf)
print(buf.decode(errors="replace").strip())
PY
}

# Register driver + conversation for member routing.
rpc '{"jsonrpc":"2.0","id":"1","method":"driver.register","params":{"driverID":"d-mesh","kind":"agy"}}' \
  "$DATA/logs/driver-register.json"
rpc '{"jsonrpc":"2.0","id":"2","method":"conversation.register","params":{"driverID":"d-mesh","vendorSessionID":"member-mesh-1","kind":"agy","memberID":"member-mesh-1"}}' \
  "$DATA/logs/conversation-register.json"

"$MESH" init --data-dir "$DATA/host" --name box-host >"$DATA/logs/host-init.json"
HOST_DEVICE=$(python3 -c 'import json;print(json.load(open("'"$DATA/logs/host-init.json"'"))["deviceId"])')

RUST_LOG=error "$MESH" serve --data-dir "$DATA/host" --runtime-socket "$RUNTIME_SOCK" --relay-disabled \
  >"$DATA/logs/host-serve.json" 2>"$DATA/logs/host-serve.err" &
HOST_MESH_PID=$!
for _ in $(seq 1 50); do
  if grep -q '"status": "listening"' "$DATA/logs/host-serve.json" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
HOST_ENDPOINT=$(python3 -c 'import json;print(json.load(open("'"$DATA/logs/host-serve.json"'"))["endpointId"])')
HOST_ADDR=$(python3 -c 'import json;print(json.dumps(json.load(open("'"$DATA/logs/host-serve.json"'"))["endpointAddr"]))')
HOST_TG=$(python3 -c 'import json;print(json.load(open("'"$DATA/logs/host-serve.json"'"))["trustGroupId"])')

# Client shares trust group (pairing smoke separate; here we align group for RPC).
"$MESH" init --data-dir "$DATA/client" --name box-client >"$DATA/logs/client-init.json"
python3 - <<PY
import json
from pathlib import Path
p = Path("$DATA/client/node-identity.json")
ident = json.loads(p.read_text())
ident["trustGroupId"] = "$HOST_TG"
ident["membershipEpoch"] = 1
p.write_text(json.dumps(ident, indent=2))
print(ident["deviceId"])
PY

REQ="$DATA/submit-member.json"
cat >"$REQ" <<EOF
{"jsonrpc":"2.0","id":"xhost-1","method":"delivery.submit-member","params":{"memberID":"member-mesh-1","idempotencyKey":"mesh:box-smoke:1","payload":"{\"body\":\"box-headless-mesh\",\"room\":\"smoke\"}"}}
EOF

RUST_LOG=error "$MESH" call \
  --data-dir "$DATA/client" \
  --peer-endpoint "$HOST_ENDPOINT" \
  --peer-addr "$HOST_ADDR" \
  --host-device-id "$HOST_DEVICE" \
  --request-file "$REQ" \
  --relay-disabled \
  >"$DATA/logs/peer-call.json"

python3 - <<PY
import json, re
from pathlib import Path
raw = Path("$DATA/logs/peer-call.json").read_text()
obj = json.loads(raw[raw.find("{"):])
inner = json.loads(obj["jsonrpcResponse"])
assert "result" in inner, inner
assert inner["result"].get("submitted") is True or inner["result"].get("delivery"), inner
print("BOX_HEADLESS_PEER_CALL_OK", inner["result"].get("deliveryID") or inner["result"].get("delivery",{}).get("id"))
PY

# Trust pairing smoke (invite/accept crypto) without live dial.
INV=$(RUST_LOG=error "$MESH" invite --data-dir "$DATA/host" --endpoint-id "$HOST_ENDPOINT" --address-ticket local | tail -n1)
PAIR_DIR="$DATA/pair-accept"
mkdir -p "$PAIR_DIR"
RUST_LOG=error "$MESH" accept --data-dir "$PAIR_DIR" --invitation "$INV" --name pair-peer \
  >"$DATA/logs/pair-accept.json"
python3 - <<PY
import json
from pathlib import Path
raw = Path("$DATA/logs/pair-accept.json").read_text()
obj = json.loads(raw[raw.find("{"):])
assert obj["acceptance"]["trustGroupId"]
print("TRUST_PAIRING_OK", obj["acceptance"]["trustGroupId"])
PY

echo "SMOKE_BOX_DONE data=$DATA"
