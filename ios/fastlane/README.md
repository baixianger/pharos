# PharosMobile — fastlane

Modeled on the sibling `hetznerly` project. Uses **App Store Connect API key
(.p8)** auth, not an Apple ID. `me.pai.pharos.mobile`, team `TN7ZDD72P2`,
automatic signing (from `project.yml`).

## Setup (once)

```bash
cd ios
bundle install                      # installs fastlane from the Gemfile
cp fastlane/.env.example .env       # then fill in the values (.env is gitignored)
```

`device_install` needs **no** API key — just sign into Xcode → Settings →
Accounts once and enable Developer Mode on the device. The `.env`/`.p8`/`match`
values are only for the TestFlight/App Store lanes.

## Install onto a paired iPhone/iPad (no App Store account needed)

```bash
bundle exec fastlane device_install            # first paired device
bundle exec fastlane device_install udid:XXXX  # or a specific device
```

Automatic signing + `-allowProvisioningUpdates`; installs via `devicectl`.
Prerequisites: device unlocked, this Mac trusted, Developer Mode on
(Settings → Privacy & Security → Developer Mode).

## TestFlight (internal — no App Review)

```bash
bundle exec fastlane create_asc_app         # once, if the app isn't in ASC yet
bundle exec fastlane beta                   # build Release + upload
bundle exec fastlane ensure_beta_group      # once: internal "Internal" group
bundle exec fastlane invite_to_group email:you@example.com
```

Internal testers must be ASC team members (`list_asc_users` to check). Build
sits in Processing ~5–15 min before it's installable in the TestFlight app.

## Lanes

| Lane | What it does |
|------|--------------|
| `device_install` | Dev-signed `.ipa` → paired device via devicectl. Optional `udid:`. |
| `bootstrap` | Register App ID + sync match dev/appstore profiles (TestFlight path only). |
| `certs` | Sync App Store certs/profiles via match. |
| `bump_build` | Build number ← `git rev-list --count HEAD`. |
| `beta` | Release build → TestFlight. |
| `create_asc_app` | Create the App Store Connect record (once). |
| `ensure_beta_group` | Idempotent internal TestFlight group. `name:` (default `Internal`). |
| `invite_to_group` | Create + assign a tester. `email:` `group:` `first_name:` `last_name:`. |
| `list_asc_users` | List ASC team members (eligible internal testers). |
| `stage_listing` / `release` | App Store metadata staging / submit. See note below. |

## Notes / pitfalls baked in

- **`api_key` vs `api_key_path`** — the api_key hash is built *before* the env
  var is unset (`with_env_unset`), so actions don't hit "Unresolved conflict".
- **`force_legacy_encryption: true`** on `match` — LibreSSL/fastlane-sirp bug on
  Apple Silicon; drop once on fastlane ≥ 2.233.
- **VPN DNS** — if TestFlight upload fails with `SSL_connect`/`Connection reset`,
  Tailscale may be intercepting `api.appstoreconnect.apple.com`
  (`dscacheutil -q host -a name api.appstoreconnect.apple.com` should be `17.x`).
  Fix with `tailscale up --accept-dns=false` while shipping.
- **Personal-app caveat** — Pharos connects to a Tailscale-bound broker on your
  own Mac, so a public App Review reviewer can't exercise it. Prefer TestFlight
  internal testing (your own devices, no review). `stage_listing`/`release` are
  included but public review would need a demo mode first.
- `project.yml` regenerates `PharosMobile.xcodeproj` via `xcodegen` in
  `before_all`; don't run two lanes concurrently against the same checkout.
