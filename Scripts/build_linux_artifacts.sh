#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PLATFORM=${1:-}
OUTPUT_DIR=${2:-"$ROOT/dist/linux"}

case "$PLATFORM" in
  amd64|arm64) ;;
  *) echo "usage: Scripts/build_linux_artifacts.sh amd64|arm64 [OUTPUT_DIR]" >&2; exit 2 ;;
esac

command -v docker >/dev/null || { echo "error: docker is required" >&2; exit 1; }

IMAGE="pharos-rust-build-${PLATFORM}-$$"
CONTAINER=""
cleanup() {
  if [[ -n "$CONTAINER" ]]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build \
  --platform "linux/$PLATFORM" \
  --file "$ROOT/Dockerfile.mesh-linux" \
  --tag "$IMAGE" \
  "$ROOT"

CONTAINER=$(docker create --platform "linux/$PLATFORM" "$IMAGE")
mkdir -p "$OUTPUT_DIR"
docker cp "$CONTAINER:/usr/local/bin/pharos" "$OUTPUT_DIR/pharos"
docker cp "$CONTAINER:/usr/local/bin/pharos-meshd" "$OUTPUT_DIR/pharos-meshd"
docker cp "$CONTAINER:/usr/local/bin/pharos-web" "$OUTPUT_DIR/pharos-web"
# Compat alias for package_deb / older docs that still look for pharos-mesh.
cp "$OUTPUT_DIR/pharos" "$OUTPUT_DIR/pharos-mesh"
chmod 0755 "$OUTPUT_DIR/pharos" "$OUTPUT_DIR/pharos-mesh" "$OUTPUT_DIR/pharos-meshd" "$OUTPUT_DIR/pharos-web"

docker run --rm --platform "linux/$PLATFORM" --entrypoint /bin/sh "$IMAGE" \
  -c 'ldd /usr/local/bin/pharos && /usr/local/bin/pharos --help >/dev/null'
