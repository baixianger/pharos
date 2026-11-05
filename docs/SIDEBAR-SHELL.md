# Pharos Agent Sidebar Shell

Status: proposed macOS shell, informed by the external `dsh-ios` drawer implementation.

## Product hierarchy

The sidebar represents how work is resumed, not how records are stored.

1. New Session
2. Projects
3. Rooms
4. Settings
5. Pinned rooms and sessions
6. Active sessions

Issues and milestones do not appear in the global sidebar. They remain inside a
project workspace. Agent vendors do not become navigation groups.

Project management remains a first-class Pharos capability, but it becomes the
context layer behind sessions rather than the dominant global navigation model.
Project colors, ordering, Work Items, milestones and activity are preserved.

## Geometry

- Expanded width: 288 pt, user-resizable from 248 to 360 pt.
- Collapsed state: hidden rather than an information-poor icon rail.
- Outer sidebar padding: 10 pt.
- New Session capsule: 44 pt high, 22 pt continuous radius.
- Top utility buttons: two 44 x 44 pt continuous rounded squares, 13 pt radius.
- Navigation rows: 34 pt.
- Session rows: 38 pt with a 16 pt kind mark, title and trailing state.
- Selected row radius: 9 pt.
- Main surface radius while sidebar is exposed: 24 pt.
- Main surface shadow appears only during overlay or interactive dragging.

## Fixed action region

The top region never scrolls.

- `New Session` is the only emphasized control.
- Search opens the session and room command palette.
- The sidebar toggle hides the custom surface and is available through a toolbar
  button and keyboard shortcut.
- Projects and Rooms show counts, not nested children.
- Settings is a normal navigation row and does not compete with New Session.

## Pharos identity system

Pharos must not flatten every source until it becomes visually anonymous.

- Project color is the primary context accent: a 3 pt leading marker on project
  and project-backed session rows, plus the selected conversation header.
- Agent kind is a compact neutral mark plus text: `Codex`, `Claude`, or `DSH`.
- Runtime state uses semantic status color and never borrows the project accent.
- Rooms use the existing Mesh identity and unread treatment.
- A Scratch session has a neutral context marker and can later adopt a project.

This hierarchy keeps a blue Pharos project recognizable across three different
agents without pretending those agents have identical capabilities.

## New Session flow

The capsule opens one compact command sheet:

1. Choose `New` or `Resume history`.
2. Choose a project or Scratch.
3. Choose Codex, Claude or DSH. Default to the project's last used agent.
4. Optionally attach the session to a room.
5. Start or resume.

History belongs in this flow and in search; it is not another permanent sidebar
section.

The flow follows DeepSeek Harness's Session Intent principle: allocate one stable
Pharos conversation identity before the vendor runtime is materialized. Project,
room and agent choices refine that same object instead of creating temporary rows.

## Pinned region

Pinned items are explicit user shortcuts and may mix object types.

- Room row: room glyph, room name, unread count.
- Session row: agent kind glyph, title, state dot, optional room glyph.
- Dragging reorders pins locally; the registry persists stable object IDs.
- A missing or external session remains pinned but receives a degraded label.
- Pinning a session never pins its tmux pane or surface identity.

## Active sessions

- Sort by `needs attention`, then latest runtime activity.
- Show at most eight rows before `Show all sessions`.
- Do not group by vendor.
- Use type labels in accessibility text; color and icon are secondary cues.
- Runtime state is authoritative. tmux fallback is shown as `Fallback`, never as
  a normal active state.
- Pending approval or user input outranks `working`; background subagent activity
  remains secondary status rather than making an idle parent appear active.
- Project groups keep explicit user order. Session activity may reorder the flat
  Active list, but it never unexpectedly moves projects.

## Workspace browser behavior

DeepSeek Harness Web separates its sidebar shell from the Workspace browser. Use
the same boundary in Pharos:

- The shell owns New Session, collapse, scrolling seats and Settings placement.
- The project browser owns project rows, project color, expansion and session rows.
- The room browser owns room pins, unread state and room selection.
- The runtime projection owns normalized session state and attention priority.
- Each expanded project initially shows five sessions, then `Show more`.
- Sessions without a valid project remain under `Scratch`, not an invented project.

## Motion

The DSH iOS source uses a fixed lower drawer and a moving upper main surface.
Pharos keeps that model but adapts it for desktop:

- Toolbar toggle: 280 ms spring, low bounce.
- Collapsed desktop mode may retain a 56 pt utility rail when the window is wide;
  narrow overlay mode closes to zero so the conversation keeps usable width.
- Dragging from the leading 12 pt edge is interactive.
- Trackpad navigation gestures outside that edge remain untouched.
- Main surface translation and radius derive from one normalized progress value.
- Respect Reduce Motion by replacing the spring with a short opacity transition.

## Implementation boundary

Use a custom SwiftUI `ZStack`, not `NavigationSplitView`, for the outer shell.
Existing destinations remain views owned by the current navigation model. The
shell consumes normalized project, room, pinned-item and runtime-session records;
it does not query tmux or vendor backends directly.

Keep the shell, project browser, room browser and session projection as separate
components. This mirrors the DSH Web slot boundary and prevents the sidebar view
from becoming another monolithic data owner.

The first implementation should replace only the presentation shell. Data
migration, Issue renaming and Runtime transcript projection are separate changes.
