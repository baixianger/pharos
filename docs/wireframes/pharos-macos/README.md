# Pharos macOS Workspace Wireframes

Low-fidelity proposal for moving Pharos from an issue-heavy project manager to
an agent-session control plane.

## Screens

- `command-center.puml`: attention-first home screen.
- `sessions.puml`: unified Claude, Codex, and DSH session control.
- `project-workspace.puml`: project work items with a detail and inspector split.
- `inbox.puml`: approvals, directed messages, and runtime notices.
- `navigation-flow.puml`: primary transitions between screens.

## Product rules represented here

- Sessions are a top-level product object.
- Work Items replace Issue-heavy navigation without requiring an immediate data migration.
- One primary action per selected object.
- Vendor choice is secondary to starting or resuming work.
- tmux and transport details stay out of the normal interface.
- Runtime state is authoritative; fallback sessions are visibly degraded.

## Open questions

- Should `Work Items` be labelled `Tasks` in the shipping UI?
- Should approvals live only in Inbox, or also appear inline in Session detail?
- Should completed Sessions remain in the main list or move to History automatically?
