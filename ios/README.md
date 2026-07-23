# Pharos for iPhone and iPad

This directory is an XcodeGen application target for using the same local-first,
signed Pharos Mesh replica from iPhone and iPad.

## Transport contract

| Concern | Owner | Transport | Security boundary |
|---|---|---|---|
| Projects, issues, rooms, messages | Every trusted device | signed event sync over Iroh QUIC | Ed25519 device identity plus current membership epoch |
| Attachments | Content-addressed local replicas | verified bounded chunks over Iroh | SHA-256 digest checked before publication |
| Live refresh | iOS app while foregrounded | bounded bidirectional anti-entropy | direct or encrypted relay path; IP address is never identity |
| Agent wake-up | owning Host | signed directed command with durable receipt | membership role, Host identity, resource generation, and deadline |
| Interactive control | iOS app to the member's Mac | Citadel PTY + SwiftTerm over LAN or Tailscale, resolving the reported pane to its exact tmux session | explicit target confirmation; same device-local key and host-key opt-in |
| Spawn member | selected member host | SSH over LAN or Tailscale invoking that host's `pharos mesh spawn` | shared CLI owns hooks, tmux, launch flags, and join confirmation |
| Non-secret configuration | one iOS device | `UserDefaults` | Host profiles stay device-local |
| SSH private key | one iOS device | Keychain, `AfterFirstUnlockThisDeviceOnly` | never iCloud-synced |

The iOS app consumes the shared protocol, identity, replica, transport, and
trust-group lifecycle packages; all Pharos clients and services are released as
one protocol generation during rapid development.

## Create, invite, join, and leave

- First launch offers **Create personal Mesh** and **Join an existing Mesh**.
- **Invite a device** creates a signed, single-use link that expires after five
  minutes. Share it with the system sheet through AirDrop, Mail, or Messages,
  copy it, or let the other device scan its QR code.
- Opening a `pharos://device` link in iOS enters the same signed review and join
  flow as scanning the QR code.
- When joining another trust group, **Archive current Mesh and switch** retains
  the previous local replica without claiming remote revocation.
- **Leave current Mesh and switch** publishes a signed membership transition
  and clears the active selection only after a surviving Mesh admin device
  confirms it. Keep a second admin device online for this path.

## Deliberate boundaries

- iCloud is not used for live project or configuration synchronization.
- No Broker is authoritative in normal operation. Host-owned runtime state is
  intentionally not replicated.
- iOS suspends arbitrary sockets in the background. This version refreshes in
  the foreground; reliable background notifications require an APNs relay.
- Removing a trusted device advances a Mesh-admin-signed membership epoch.
  The local signed-invitation role is persisted; replica-only devices cannot
  invite or revoke devices, and those controls remain unavailable in Settings.
  Rotate keys by pairing and verifying a replacement, then removing the old key;
  keep three Mesh admin devices for one-offline recovery. If two admins
  concurrently approve different roster changes, bring the third current
  admin online and retry the intended change.
- SSH host-key pinning is not yet wired. The app requires a per-host risk toggle
  before using Citadel's `acceptAnything()` validator, and should only connect
  through the private tailnet.
- The iOS app never pokes tmux over SSH. The Host node validates a numeric pane,
  the expected Claude/Codex process tree, and a visibly idle composer locally.
- Remote control shows the host, SSH user, member, and pane before attaching.
  Closing the full-screen terminal disconnects SSH.
- Mobile spawn delegates to the remote host's installed Pharos CLI; the iOS app
  deliberately does not duplicate desktop hook, keychain, or tmux bootstrap logic.

## References used

- Hetznerly (external sibling repo, read-only): XcodeGen configuration,
  Citadel Ed25519 authentication, and device-local Keychain identity design.
- Clawbox (external private GitHub repo, read-only): document-waterfall chat,
  `LazyVStack` transcript, multiline composer, and MarkdownUI rendering.
- Wick (external sibling repo, read-only): stable MarkdownUI wrapper and code
  block styling derived from Clawbox.

## UI dependency decision

- [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) 2.4.1 renders
  agent responses with the Clawbox document-waterfall treatment.
- [Exyte Chat](https://github.com/exyte/Chat) was evaluated, but Pharos does not
  need its media picker or generic message model. Native SwiftUI
  `ScrollView`/`LazyVStack`/`safeAreaInset` keeps agent state, Markdown, and poke
  feedback first-class and gives `NavigationSplitView` an uncomplicated iPad
  layout.
- [Citadel](https://github.com/orlandos-nl/Citadel) 0.12.1 provides SSH command
  execution using the same dependency and identity path as Hetznerly.
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.14.0 renders the
  interactive terminal; the Wellz26 NIOSSH fork matches Citadel's dependency.

## Build and test

```bash
cd ios
xcodegen generate
xcodebuild -project PharosMobile.xcodeproj \
  -scheme PharosMobile \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project PharosMobile.xcodeproj \
  -scheme PharosMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  CODE_SIGNING_ALLOWED=NO test
```

SSH keys are still required for interactive terminal attachment and remote
agent launch, and the target Host must be reachable over the same LAN or
Tailscale. SSH is not required for Mesh message delivery or Poke.

## Last verified

2026-07-21:

- 26 Swift Testing cases passed on an iPhone 17 Pro simulator;
- the app built and launched on an iPad Air 13-inch simulator;
- interactive SSH/tmux and remote-spawn command paths compile under Swift 6
  strict concurrency; safety tests cover exact pane resolution and injection;
- simulator runtime proof covered pairing, rich project/issue fields, chat reply,
  iOS write-to-Mac sync, offline presentation, and reconnect convergence;
- the shared package suite passed 299 tests, including signed revocation,
  transition replay/conflict handling, and offline-survivor catch-up.
