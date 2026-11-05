# Pharos — site

Landing page + privacy policy for Pharos (macOS `me.pai.pharos`,
iOS companion `me.pai.pharos.mobile`), following the pattern of
[pendler-app](https://github.com/baixianger/pendler-app).

- `index.html` — landing page (self-contained, light/dark via `prefers-color-scheme`)
- `privacy.html` — written 2026-07-19 from a source audit of
  `~/personal/pharos` (local-first storage, user-run mesh broker over
  Tailscale/SSH only, Keychain-held SSH keys, Sparkle present but dormant,
  no analytics/telemetry SDKs)
- `shots/`, `icon.png` — from `pharos/site/shots/` and `pharos/site/icon.png`

Note: `pharos/site/` contains an older, fancier landing page (external
Google Fonts, separate `style.css`, placeholder `#` download links, no
privacy page). This directory is the self-contained replacement; merge or
choose between them before publishing.

## Deploy (impai.me — NOT GitHub Pages)

GitHub Pages publishing was cancelled 2026-07-19. These pages now ship as a
subpath of impai.me (Vite site at ~/brainstorm/home-page, nginx on personal-ts
serving /var/www/impai/current). Staging tree with the proposed layout:

    ~/personal/impai-apps-staging/apps/pharos/

Proposed URL: https://impai.me/apps/pharos/ (+ privacy.html). All links in the
pages are relative, so no edits are needed for the subpath. publish.sh is
neutered on purpose. Production deploy is the human's call.
