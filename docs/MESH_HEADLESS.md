# Pharos Mesh on Linux

Linux participates as a normal device in the local-first trust group. It owns a
signed SQLite replica and Iroh identity, synchronizes in both directions, and
can keep serving while either Mac is offline. It is not a global writer or a
trusted network perimeter.

```text
Mac replica ──┐
iOS replica ──┼── encrypted Iroh direct/relay paths ── Linux replica
Mac replica ──┘                                      signed SQLite + blobs
```

Every mutation is signed by its author. Membership is an epoch-scoped signed
roster; deterministic merge rules resolve concurrent offline writes. Iroh relay
operators can observe connection metadata but not Pharos payload plaintext.

## Install

GitHub Releases publish `amd64` and `arm64` Debian packages. Each package
contains the Swift CLI and the pinned Rust `libiroh_ffi.so` used to build it.

```sh
sudo apt install ./pharos-mesh_VERSION_ARCH.deb
```

Installation deliberately leaves `pharos-mesh.service` disabled. This prevents
an upgrade from restarting the retired TCP Broker or silently creating a new,
unrelated trust group.

## Pair or initialize

To make this Linux machine the first device in a new personal group:

```sh
sudo -u pharos-mesh pharos-mesh distributed init \
  --data-dir /var/lib/pharos-mesh
```

Normally, pair it into the existing group instead. Create an invitation on an
existing controller, accept it on Linux, and redeem the returned acceptance on
the inviter. The shared CLI exposes the exact two-step commands:

```sh
pharos-mesh distributed device-invite --data-dir ABSOLUTE-PATH
pharos-mesh distributed device-accept INVITATION --name linux \
  --data-dir /var/lib/pharos-mesh
pharos-mesh distributed device-redeem INVITATION ACCEPTANCE \
  --data-dir ABSOLUTE-PATH
```

Pairing secrets are bearer credentials: transfer them privately and do not put
them in shell history, logs, or tickets. The macOS and iOS pairing screens use
the same signed protocol.

After the Linux identity has an active membership, start its service:

```sh
sudo systemctl enable --now pharos-mesh.service
sudo systemctl status pharos-mesh.service
```

The service runs:

```sh
pharos-mesh distributed sync-serve \
  --data-dir /var/lib/pharos-mesh --relay production
```

No public TCP bind or Tailscale address is required. Direct paths are preferred;
the configured Iroh relay is the connectivity fallback.

## Container

`Dockerfile.mesh-linux` builds the pinned Rust FFI library, links the Swift
executable against it, and copies both into the runtime image:

```sh
docker build -f Dockerfile.mesh-linux -t pharos-mesh .
docker run --rm -v pharos-data:/data pharos-mesh \
  distributed init --data-dir /data
docker run -d --name pharos-mesh --restart unless-stopped \
  -v pharos-data:/data pharos-mesh
```

Initialize only for a brand-new group. For an existing group, perform the
pairing handshake against the same persistent volume before starting the
long-running container.

## Host command boundary

`distributed sync-serve --host` additionally enables explicitly registered,
generation-bound host resources such as a tmux pane. Run that mode as the user
who owns those resources, never as the system service's `DynamicUser`. Commands
are signed, deadline-bound, replay-protected, and restricted to registered
actions; arbitrary remote shell execution is not part of Mesh.

## Backup, recovery, and migration

- Back up the whole `/var/lib/pharos-mesh` directory while the service is
  stopped, including the SQLite database, identity, and blob directory.
- Keep at least two controller devices. A surviving controller can pair a
  replacement and revoke a lost device by advancing the signed membership
  epoch.
- Key rotation is pair-new, verify synchronization, then revoke-old.
- The legacy TCP Broker and Node require `PHAROS_LEGACY_BROKER=1` and exist only
  for an explicit migration rollback. They are not installed as active Linux
  services.
- See `MIGRATION-RELEASE-CYCLE.md` for the tested backup, import, cutover,
  rollback, and re-cutover procedure.

## Release verification

CI builds the pinned Rust library and Swift CLI for Linux, packages both into a
Debian archive, installs the archive in a clean Debian container, checks dynamic
link resolution, and runs the CLI. `Scripts/build_linux_artifacts.sh` reproduces
the same build locally on a Docker-capable host.
