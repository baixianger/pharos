# Pharos — fastlane lanes

Pharos is a **Developer ID + notarization + Sparkle** app (direct download).
It is NOT sandboxed and cannot go to the Mac App Store.
All lanes wrap the shell scripts in `../Scripts/`.

## Setup

```sh
bundle install   # installs fastlane gem
```

## Mac lanes

| Lane | Description |
|---|---|
| `bump_build` | Set `BUILD_NUMBER` in `version.env` to the current git commit count |
| `icon` | Regenerate `Icon.icns` from `assets/icon-source.png` |
| `build` | Build `Pharos.app` via `Scripts/package_app.sh` (release) |
| `sign_and_notarize` | Developer ID sign + notarize + staple + zip via `Scripts/sign-and-notarize.sh` |
| `appcast` | Generate `appcast.xml` via Sparkle's `generate_appcast` (or print manual steps) |
| `release` | Orchestrate: `bump_build` → `build` → `sign_and_notarize` → `appcast` → `gh release create` |

## Typical release

```sh
export APP_IDENTITY="Developer ID Application: Your Name (TN7ZDD72P2)"
export NOTARYTOOL_PROFILE="pharos-notary"

bundle exec fastlane mac release
```

See `../docs/RELEASE.md` for full prerequisites and the fastlane section.

## Required credentials for `sign_and_notarize` / `release`

| Env var | Required | Default |
|---|---|---|
| `APP_IDENTITY` | Yes | — |
| `NOTARYTOOL_PROFILE` | Option A | — |
| `NOTARYTOOL_APPLE_ID` | Option B | — |
| `NOTARYTOOL_TEAM_ID` | Option B | `TN7ZDD72P2` |
| `NOTARYTOOL_APP_PASSWORD` | Option B | — |
