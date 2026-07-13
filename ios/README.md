# Pharos for iPhone and iPad

This directory is an independent XcodeGen application target for operating the
existing Pharos agent mesh from iPhone and iPad.

## Transport contract

| Concern | Owner | Transport | Security boundary |
|---|---|---|---|
| Rooms, roster, history, `say` | Pharos Mesh broker on the hub Mac | newline-delimited JSON over TCP `47800` | the broker must bind only to its Tailscale address; Tailscale ACLs are the current authentication boundary |
| Live refresh | iOS app while foregrounded | one request per TCP connection, polled every 2 seconds | no arbitrary-LAN endpoint should be configured |
| Agent wake-up | iOS app to the agent's Mac | SSH over Tailscale, then guarded `tmux capture-pane` + `send-keys` | device-local Ed25519 key; explicit opt-in while host keys remain unpinned |
| Non-secret configuration | iPhone/iPad devices | `NSUbiquitousKeyValueStore` | iCloud syncs Mesh and SSH host mappings only |
| SSH private key | one iOS device | Keychain, `AfterFirstUnlockThisDeviceOnly` | never iCloud-synced |

The wire structs intentionally mirror `Sources/Pharos/MeshBroker.swift`. They
must remain backward compatible. A future cleanup can extract them into a
shared package once both apps can migrate together.

## Deliberate boundaries

- iCloud is configuration sync, not a chat relay.
- iOS suspends arbitrary sockets in the background. This version refreshes in
  the foreground; reliable background notifications require an APNs relay.
- The current desktop broker has no application token. Do not expose port
  `47800` to Wi-Fi or the public Internet.
- SSH host-key pinning is not yet wired. The app requires a per-host risk toggle
  before using Citadel's `acceptAnything()` validator, and should only connect
  through the private tailnet.
- A poke is attempted only for `stopped`/`idle` members, a numeric tmux pane,
  a recognized Claude/Codex foreground process, and a visibly idle composer.

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
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

Before first SSH poke, copy the generated public key into the target Mac's
`~/.ssh/authorized_keys`, add a mapping from the Mesh member's `host` value to
its Tailscale SSH address, and explicitly acknowledge the unpinned-host-key
limitation.

## Last verified

2026-07-14:

- six Swift Testing cases passed on an iPhone 17 Pro Max simulator;
- the app built and launched on an iPad Air 13-inch simulator;
- a read-only TCP probe reached the live Tailscale-bound broker (`list`: three
  rooms), and both simulators rendered the live roster and transcript;
- the live probe exposed and regression-tested duplicate `who` rows for agents
  joined to multiple rooms.
