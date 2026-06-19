# CLAUDE.md — Pharos

A **personal** macOS app: a project manager + coding-agent launcher.
**Personal project — never put company identity anywhere.**

## Identity & conventions (mirrors hetznerly)
- Bundle ID prefix `me.pai` → the app is **`me.pai.pharos`**. Never reuse a company/employer bundle prefix.
- Copyright: **`© 2026 Pai`**. App category: `public.app-category.developer-tools`.
- Git author: **`Pai <baixianger@gmail.com>`** (set in the repo's local git config).
- Targets **macOS 26** (Liquid Glass). Swift 6.x.

## Build / run
- Pure **SwiftPM**, no Xcode project.
- `swift build` — compile-check.
- `./Scripts/dev.sh` — build the icon, package `Pharos.app` (ad-hoc signed), launch.
- `./Scripts/package_app.sh release` — just package the `.app`.
- App icon: `assets/icon-source.png` → `./Scripts/make_icns.sh` → `Icon.icns`.

## Layout
- `Sources/Pharos/` — SwiftUI app (overview in `README.md`, spec in `DESIGN.md`).
- Registry persists to `~/Library/Application Support/Pharos/projects.json`.

## Notes
- Phase 0 pins Swift language mode v5 (in `Package.swift`) to keep the scaffold
  building; tighten toward full strict concurrency (hetznerly's standard) as the
  service layer settles.
- Design language follows Wick: Liquid Glass surfaces, hidden title bar, a
  watchlist-style sidebar, and minimal ticker-like rows.
