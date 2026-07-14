# iOS design and implementation audit

Audited 2026-07-14 against Emil Kowalski's Apple Design skill plus the local
SwiftUI UI Patterns, SwiftUI Performance Audit, and Swift Concurrency skills.

## Outcome

The project uses native navigation, sheets, forms, labels, materials, Dynamic
Type, and a two-column `NavigationSplitView` that scales naturally from iPhone
to iPad. The remote-control additions follow Apple's agency and predictability
principles: they identify the member, host, SSH user, and tmux pane before an
explicit Connect & Attach action. Spawn explains the live side effect and the
desktop workflow's elevated agent flags before enabling Spawn.

## Remediated in this pass

- Added item-driven destinations for Settings, member control, spawn, and the
  full-screen terminal so each presented surface owns its state and actions.
- Used the member-reported `%<digits>` pane as the durable target, then resolves
  its exact tmux session on the remote host. Inputs are allowlisted before any
  shell command is created.
- Kept terminal UI state on the main actor and isolated Citadel/NIO resources
  behind actors. The only unchecked transfer wrappers cover library types that
  Citadel serializes on its NIO event loop.
- Stopped the two-second foreground poll from publishing unchanged room,
  member, and message values, avoiding broad transcript and Markdown redraws.
- Replaced a fixed-size send icon with a Dynamic Type text style and made the
  transcript's convenience animation respect Reduce Motion.
- Used system labels and visible state text rather than encoding status or risk
  with color alone. Interactive controls retain specific accessibility names.

## Accepted constraints and follow-ups

- SSH currently uses Citadel's `acceptAnything()` host-key validator. Every
  remote feature remains blocked behind a per-host explicit risk toggle and is
  documented for private Tailscale use only. TOFU or pinned known-host storage
  is the highest-priority security follow-up.
- Foreground polling is intentionally simple. APNs-backed background delivery
  remains a separate product/infrastructure decision.
- The terminal itself is a fixed-grid accessibility surface by definition;
  surrounding navigation and confirmation UI still follows Dynamic Type and
  system accessibility settings.

## Verification

- iPhone 17 Pro Max simulator: 10/10 Swift Testing cases passed.
- iPad Air 13-inch simulator: application build passed.
- iPhone runtime: live Mesh room and the two new toolbar actions rendered.
- No live agent was spawned and no remote tmux session was attached during the
  audit; command construction and safety gates were exercised without external
  side effects.
