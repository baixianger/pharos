# Third-Party Notices & Attributions

Pharos incorporates design patterns, token schemas, color palettes, and procedural geometry inspired by or ported from open-source software.

---

### Grok Bot (Desktop Client & Avatar Kernel)

Portions of the user interface architecture, responsive 3-pane layout geometry, design tokens, color palette, and procedural avatar rendering in Pharos are ported from the Grok Bot open-source project.

- **Source Reference**: Grok Bot desktop application (version 0.78.5) and research archives at `~/brainstorm/collections/design/grok-bot/` and `~/brainstorm/collections/attempts/grok-bot-ui/`.
- **Components Ported / Adapted**:
  - Semantic theme palette (`sand` theme color formulas, light/dark mode contrast scales).
  - 3-pane responsive desktop geometry: 280px left roster (88px compact icon rail collapsing at `expandedWidth + 424px`), 424px minimum conversation canvas, 280–320px docked/overlay details inspector.
  - Window constraints (minimum size 512 x 520 DIP).
  - Composer geometry, variable-height expand physics, and message bubble radius formulas.
  - Procedural vector geometry, eye expressions, and activity state machine adapted for native SwiftUI `Canvas` and `TimelineView`.
- **Notices**:
  - Copyright (c) Grok Bot contributors.
  - Used in accordance with open-source licensing.
