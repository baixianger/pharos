---
name: pharos
description: Record your work in Pharos from the command line — file and triage issues, and post progress. Use whenever you discover a bug, want to propose a feature, or finish a chunk of work, so the human PM sees it instead of it being lost in your output. Pairs with the `mesh` skill (agent chat).
---

# pharos — record work as issues & progress

Pharos is the human's project manager (Linear-style, single-user). When you (an
agent) find something or make progress, **log it via the `pharos` CLI** so it
surfaces for the human — don't just mention it in your reply and lose it.

## You found a bug / an issue / a feature idea → file it
1. **Avoid duplicates first**: `pharos search "<keywords>"` (across all projects)
   or `pharos issue list <project>`.
2. **File it**:
   ```
   pharos issue add <project> "<concise title>" \
     --body "<detail: what, where (cite file:line), repro steps / why it matters>" \
     --priority <none|low|medium|high|urgent> \
     --label <bug|feature|chore|…>
   ```
   Title = one line. Body = the substance — cite `file:line`, give repro steps, or
   state the proposal. A vague report is nearly useless; a specific, verifiable one
   is gold.

## You made progress / finished → update it
- **Post a progress note** to the project log (optionally tied to an issue):
  `pharos update add <project> "<what you did / decided>" --issue <#>`
- **Move an issue's state**: `pharos issue status <project> <#> <backlog|todo|in_progress|done|canceled>`
- **Set priority**: `pharos issue priority <project> <#> <none|low|medium|high|urgent>`
- **Relate issues**: `pharos issue link <project> <#> <relates|blocks|blocked-by|duplicate> <#>`

## Read what's there
- `pharos issue list <project> [--all] [--status <s>] [--priority <p>] [--label <l>] [--milestone <m>]`
- `pharos overview [--json]` — cross-project rollup (counts, blocked, milestones).
- `pharos search "<query>"` — title / body / label / number, across projects.

## Etiquette
- **Reference issues as `project#number`** (e.g. `web#3`) in bodies, progress notes, and chat — Pharos renders that form as a clickable link that pops the issue open.
- One issue = one concrete thing. **Search before filing.**
- Logging is cheap and it's how the human stays in the loop — when in doubt, file it.
- If you're collaborating in a room (`mesh` skill) and surface a bug mid-discussion,
  file it here so it outlives the conversation.
