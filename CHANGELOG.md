# Changelog

Maps Pharos versions to git history. Newest at top.
`MARKETING_VERSION` / `BUILD_NUMBER` live in `version.env`.

---

## Unreleased

- Wick-style sidebar: watchlist group switcher (group name + ellipsis menu to
  switch / add / delete groups); minimal project rows = name + commit-activity
  sparkline; immersive hidden-title-bar window chrome.
- Import from GitHub (`gh`) with checkbox multi-select + group assignment.
- Local repos auto-detect their git origin remote on add.
- Personal identity: bundle id `me.pai.pharos`, `© 2026 Pai` (no company info).

## v0.1.0

- Phase 0 scaffold: SwiftUI + Liquid Glass (macOS 26) project manager, built as
  a pure SwiftPM app (no Xcode project).
- Project registry (local folders + GitHub), groups, JSON persistence.
- Git status panel, launch Claude Code / Codex with a project-level YOLO toggle,
  GitHub clone-to-local. Lighthouse app icon.
