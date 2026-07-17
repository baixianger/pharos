# Pharos Mesh Headless Architecture

Pharos Mesh can run as an independent Linux service. The Broker owns durable
portable project and chat data; macOS, iOS, and coding-agent CLIs are clients.

```text
Mac app ────────┐
iPhone app ─────┼── Tailscale TCP ── pharos-mesh ── JSONL transcripts
Agent CLI ──────┘                         ├───────── attachment blobs
                                         ├───────── projects.json + backups
                                         └───────── presence/unread state
                                                   │ event cursor
                    tmux agents ◀── pharos node ◀──┘
```

## Boundary

`PharosMeshCore` contains the portable wire protocol, TCP/UDS transport,
broker, transcript persistence, reply resolution, and attachment storage.
`pharos-mesh` is the portable executable. The `Pharos` executable remains a
macOS product because project launching, AppKit, Finder, and Keychain are not
server responsibilities. `pharos-mesh node` is a separate per-user Host worker:
it receives constrained Poke events and controls only registered tmux panes
owned by that user.

The headless Broker owns `projects.json` as opaque portable data. Reads carry a
SHA-256 revision; writes require that revision and fail on conflicts. It does
not launch agents or store/resolve Host checkout paths.

Broker machines and execution Hosts are separate concepts. A Linux server may
run only the Broker, while macOS or Linux execution Hosts run a per-user node.
The node connects outward to the Broker, so execution Hosts expose no inbound
port. SSH remains an install/recovery fallback. Installing the Broker package
does not grant it arbitrary shell access to those Hosts. See
[`ADR-001-BROKER-AND-HOSTS.md`](ADR-001-BROKER-AND-HOSTS.md).

## Protocol v2

- `capabilities` prevents a new client from silently sending advanced fields to
  an old broker that would ignore them.
- Every new message receives a UUID. A deterministic legacy key keeps old JSONL
  rows quoteable without rewriting history.
- A reply stores both the original message ID and a short immutable snapshot, so
  it remains useful when the original is outside the client's history window.
- Attachments are uploaded before `say`; the message references verified
  metadata only.
- `registry-get` and `registry-put` implement compare-and-swap project storage
  (`registry-cas-v1`). Every accepted change backs up the prior snapshot.

## Attachment transport

Control frames remain newline-delimited JSON. `attachment-put` sends one JSON
header followed by exactly `byteSize` raw bytes. `attachment-get` returns one
JSON header followed by the raw bytes. This avoids Base64 expansion and the
mobile client's ordinary 4 MiB JSON response limit.

The broker enforces a 25 MiB limit, verifies SHA-256 before committing, writes
atomically, rejects path traversal, and stores:

```text
<data-dir>/mesh/attachments/<attachment-id>/metadata.json
<data-dir>/mesh/attachments/<attachment-id>/data
```

## Linux service

Example foreground invocation:

```bash
pharos-mesh serve \
  --bind 100.78.109.51:47800 \
  --data-dir /var/lib/pharos-mesh
```

Only bind a Tailscale address. The current transport relies on the tailnet as
its trust boundary and does not contain application-level authentication.

From another tailnet device, verify the service directly:

```bash
pharos-mesh capabilities --endpoint 100.78.109.51:47800
```

## Host node

Install the node as the same user that owns the tmux sessions:

```bash
pharos-mesh node install --endpoint 100.78.109.51:47800
```

On macOS this installs `~/Library/LaunchAgents/me.pai.pharos.mesh-node.plist`.
On Linux it installs and enables a user systemd unit. The Debian package also
ships `pharos-mesh-node.service` under the systemd user-unit directory.

The node keeps an outbound, cursor-based event subscription to the Broker. A
Poke is accepted only when its Tailscale IP/Host identity matches, the exact
tmux pane and socket are still present, the expected Codex/Claude process is in
that pane's process tree, and the composer is visibly idle. It never accepts an
arbitrary shell command from Mesh.

Foreground macOS/iOS clients use the same Broker-held event requests and keep a
low-frequency snapshot refresh for reconnect recovery. iOS background delivery
still requires APNs because the operating system suspends private TCP sessions.

Suggested systemd hardening:

```ini
[Service]
User=pharos-mesh
Environment=PHAROS_MESH_BIND=100.78.109.51:47800
ExecStart=/usr/local/bin/pharos-mesh serve --bind ${PHAROS_MESH_BIND} --data-dir /var/lib/pharos-mesh
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/lib/pharos-mesh
```

The repository includes a complete unit at `Deploy/pharos-mesh.service` and an
environment-file example. `47800` matches the desktop client's existing Mesh
port, so moving from a Mac hub does not require a protocol-specific port change.

## Debian and Ubuntu installation

Release automation publishes signed `amd64` and `arm64` packages to the Pharos
APT repository. Configure it once:

```bash
curl -fsSL https://baixianger.github.io/pharos/apt/pharos.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/pharos-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/pharos-archive-keyring.gpg] https://baixianger.github.io/pharos/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/pharos.list
sudo apt update
sudo apt install pharos-mesh
```

Repository signing-key fingerprint:
`4FF9 7A0C 8CE2 921B 1C43 A105 63AD D441 9E1D CB73`.

The package starts on `127.0.0.1:47800`. To accept tailnet clients, set this
host's Tailscale IPv4 in `/etc/pharos-mesh.env` and restart the service:

```bash
sudo systemctl restart pharos-mesh
```

The package preserves `/etc/pharos-mesh.env` and `/var/lib/pharos-mesh` across
upgrades.

## Reliability and operations

- Back up the whole data directory, not only `projects.json`.
- The Broker keeps the newest 200 automatic registry versions under
  `<data-dir>/registry-backups/`.
- Transcripts and attachments are durable; unread mailboxes are runtime state.
- Uploads are checksum-verified and atomically committed.
- A room delete removes its transcript. Attachment garbage collection is a
  separate future task so a mistaken delete cannot immediately destroy files.

## Tradeoffs and future revisions

- The single broker is intentionally simple and sufficient for a personal
  tailnet. It is not horizontally replicated.
- The current server trusts Tailscale membership. Add per-device tokens or mTLS
  before exposing it beyond a private tailnet.
- Large-file resumable uploads, thumbnail generation, retention policies,
  full-text search, and multi-broker replication should be revisited only if
  usage outgrows the personal 25 MiB/file model.
