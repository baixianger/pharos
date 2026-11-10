#!/usr/bin/env bash
# Start Runtime + mesh serve on HOST for XHOST smoke. Prints JSON status line.
set -euo pipefail
ROOT="${ROOT:?}"
DATA_DIR="${DATA_DIR:?}"
MESH_BIN="${MESH_BIN:-$ROOT/rust/target/debug/pharos-mesh-node}"
MESHD_BIN="${MESHD_BIN:-$ROOT/rust/target/debug/pharos-meshd}"
# If unset → --relay-disabled (local smoke). Set RELAY_FLAG="" to enable relays.
RELAY_FLAG="${RELAY_FLAG---relay-disabled}"
mkdir -p "$DATA_DIR"/{host,runtime-host,logs}
RUNTIME_SOCK="$DATA_DIR/runtime-host/agent.sock"
rm -f "$RUNTIME_SOCK"

"$MESHD_BIN" --socket "$RUNTIME_SOCK" --data-dir "$DATA_DIR/runtime-host" \
  >"$DATA_DIR/logs/meshd.log" 2>&1 &
echo $! >"$DATA_DIR/logs/meshd.pid"
sleep 0.5

python3 - "$RUNTIME_SOCK" <<'PY'
import socket, sys, json
sock = sys.argv[1]
def rpc(obj):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(sock)
    s.sendall((json.dumps(obj) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf.decode())
print(rpc({"jsonrpc":"2.0","id":"1","method":"driver.register","params":{"driverID":"d-mesh","kind":"agy"}}))
print(rpc({"jsonrpc":"2.0","id":"2","method":"conversation.register","params":{"driverID":"d-mesh","vendorSessionID":"member-mesh-1","kind":"agy","memberID":"member-mesh-1"}}))
PY

RUST_LOG=error "$MESH_BIN" init --data-dir "$DATA_DIR/host" --name xhost-host \
  >"$DATA_DIR/logs/host-init.json"
RUST_LOG=error "$MESH_BIN" serve --data-dir "$DATA_DIR/host" \
  --runtime-socket "$RUNTIME_SOCK" $RELAY_FLAG \
  >"$DATA_DIR/logs/host-serve.json" 2>"$DATA_DIR/logs/host-serve.err" &
echo $! >"$DATA_DIR/logs/host-mesh.pid"
for _ in $(seq 1 80); do
  if grep -q '"status": "listening"' "$DATA_DIR/logs/host-serve.json" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
cat "$DATA_DIR/logs/host-serve.json"
