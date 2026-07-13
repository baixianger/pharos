# Pharos — Release Guide

## Why direct download, not the Mac App Store

Pharos requires capabilities that the Mac App Store explicitly forbids:

- **Spawning terminal processes** (e.g. `open -a Terminal`, `NSTask` for shells)
- **Reading `~/.claude` and `~/.codex`** — arbitrary home-directory access
- **Private SkyLight/CoreGraphics APIs** used for window management

The Mac App Store mandates the App Sandbox (`com.apple.security.app-sandbox`), which would
break all of the above. Pharos therefore uses **Developer ID + notarization** for
direct-download distribution. Hardened Runtime is still ON for notarization eligibility
and basic exploit mitigation. The sandbox entitlement must never appear in
`.build/entitlements/Pharos.entitlements`.

---

## Prerequisites

### 1. Apple Developer Program membership

Active enrollment at [developer.apple.com](https://developer.apple.com) is required.

### 2. Developer ID Application certificate

- Open **Xcode → Settings → Accounts → Manage Certificates** (or Keychain Access).
- Create a **Developer ID Application** certificate.
- The certificate must be in your **login Keychain** and trusted for code signing.
- Find the exact name with:

  ```sh
  security find-identity -v -p codesigning | grep "Developer ID Application"
  ```

  Example output:
  ```
  1) ABCDEF1234...  "Developer ID Application: Your Name (TEAMID)"
  ```

### 3. Notarytool credentials

Choose **one** of the two options below.

#### Option A — Stored keychain profile (recommended)

Run this **once** on your Mac (you'll be prompted for credentials):

```sh
xcrun notarytool store-credentials pharos-notary \
  --apple-id "you@example.com" \
  --team-id "ABCDE12345"
  # it will prompt for the app-specific password
```

You can verify it works with:

```sh
xcrun notarytool history --keychain-profile pharos-notary
```

#### Option B — Inline env vars (CI / no stored profile)

Generate an **app-specific password** at [appleid.apple.com](https://appleid.apple.com)
(Sign-In & Security → App-Specific Passwords). Do **not** use your Apple ID password.

### 4. Authorize codesign to use the key without a prompt (one-time, per Mac)

**Do this once on each signing machine, or every release fails with
`errSecInternalComponent`.** When codesign reaches for the Developer ID private
key it asks the keychain for permission via a GUI dialog. Any signing run that
isn't attached to your Aqua login session — a CI job, a detached `tmux`, a
script driven by another tool — can't show that dialog and dies immediately with
`errSecInternalComponent` (build succeeds, signing the Sparkle XPCs fails).

Fix it by adding `codesign` to the key's partition list (the standard CI
prep — it authorizes the tool so no dialog is ever needed):

```sh
# Prompts for your LOGIN keychain password (usually your macOS login password),
# read silently so it never lands in shell history:
printf 'login keychain password: '; read -rs KP; echo
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$KP" ~/Library/Keychains/login.keychain-db
unset KP
```

`→ 1 identity(ies) partitioned.` means it worked. After this, `release.sh` signs
non-interactively from any context — no keychain dialog, ever. (Clicking **Always
Allow** on the dialog achieves the same thing, but only when a run can actually
surface the dialog.)

---

## Environment variables

| Variable | Required for | Description |
|---|---|---|
| `APP_IDENTITY` | All signing | Full name of your Developer ID Application cert, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `NOTARYTOOL_PROFILE` | Option A | Name of the keychain profile created by `notarytool store-credentials` |
| `NOTARYTOOL_APPLE_ID` | Option B | Your Apple ID email |
| `NOTARYTOOL_TEAM_ID` | Option B | Your 10-character Apple Developer Team ID |
| `NOTARYTOOL_APP_PASSWORD` | Option B | App-specific password from appleid.apple.com |
| `ARCHES` | Optional | Architectures to build, space-separated. Default: `arm64 x86_64` (universal) |
| `APP_NAME` | Optional | Defaults to `Pharos` |
| `BUNDLE_ID` | Optional | Defaults to `me.pai.pharos` |

---

## Version bump

Edit `version.env` before releasing:

```sh
# version.env
MARKETING_VERSION=1.2.0   # user-visible version
BUILD_NUMBER=42            # monotonically increasing
```

---

## Release steps — one command (recommended)

`Scripts/release.sh` chains both halves and produces a **notarized DMG that
opens with no Gatekeeper prompt** (plus the zip):

```sh
# 1. Verify your Developer ID cert is available
security find-identity -v -p codesigning | grep "Developer ID Application"

# 2. Run the release (Option A — keychain profile)
APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARYTOOL_PROFILE="pharos-notary" \
Scripts/release.sh
```

It runs, in order:
1. `sign-and-notarize.sh` → build + Developer ID sign (hardened runtime) +
   notarize + staple `Pharos.app`, and emit `Pharos-<version>.zip`.
2. `make_dmg.sh` → build the styled DMG from the stapled app, then **sign +
   notarize + staple the DMG itself** (make_dmg does this automatically when
   `APP_IDENTITY` is set; without it, the DMG stays ad-hoc).

Attach the resulting `Pharos-<version>.dmg` to the GitHub Release.

**Option B — inline credentials** (CI / no stored profile): set
`NOTARYTOOL_APPLE_ID`, `NOTARYTOOL_TEAM_ID`, `NOTARYTOOL_APP_PASSWORD` instead of
`NOTARYTOOL_PROFILE`.

### Just the app (no DMG)

Run `Scripts/sign-and-notarize.sh` alone for a notarized, stapled `Pharos.app`
+ zip (steps 1 above), without building a DMG.

### Ad-hoc build (no Apple Developer account)

`Scripts/package_app.sh release && Scripts/make_dmg.sh` — an unsigned DMG whose
first launch needs **right-click → Open**. This is what shipped through 0.4.0.

---

## What `package_app.sh` does during a release build

`package_app.sh` branches on `APP_IDENTITY`:

- If `APP_IDENTITY` is empty or `SIGNING_MODE=adhoc` → ad-hoc sign (`-`)
- Otherwise → `codesign --force --timestamp --options runtime --sign "$APP_IDENTITY"`
  with the entitlements file (no sandbox entitlement)

Frameworks inside `Contents/Frameworks/` are signed individually before the
top-level bundle, satisfying Apple's nested-code requirements.

---

## Distributing the zip

Upload `Pharos-<version>.zip` directly — GitHub Releases is the recommended host.

Users who download and unzip will get a Gatekeeper-approved app (stapled ticket + 
Developer ID signature). No quarantine warning on modern macOS.

---

## Using fastlane (recommended)

fastlane wraps the shell scripts above with guard-rails, progress messages, and a
one-command release flow.

### Setup (one-time)

```sh
bundle install   # installs the fastlane gem from Gemfile
```

### Quick release

```sh
export APP_IDENTITY="Developer ID Application: Your Name (TN7ZDD72P2)"
export NOTARYTOOL_PROFILE="pharos-notary"   # Option A

bundle exec fastlane mac release
```

This runs `bump_build` → `build` → `notarize` → `appcast` → `gh release create`
in sequence, attaching the notarized zip and `appcast.xml` to a GitHub release.

### Individual lanes

```sh
bundle exec fastlane mac bump_build          # write commit-count BUILD_NUMBER to version.env
bundle exec fastlane mac icon                # regenerate Icon.icns
bundle exec fastlane mac build               # package Pharos.app (release)
bundle exec fastlane mac sign_and_notarize   # sign + notarize + staple + zip
bundle exec fastlane mac appcast             # generate appcast.xml (or print manual steps)
bundle exec fastlane mac release             # full pipeline
```

### Required env vars for notarize / release

| Env var | Option | Default |
|---|---|---|
| `APP_IDENTITY` | Required | — |
| `NOTARYTOOL_PROFILE` | A (recommended) | — |
| `NOTARYTOOL_APPLE_ID` | B | — |
| `NOTARYTOOL_TEAM_ID` | B | `TN7ZDD72P2` |
| `NOTARYTOOL_APP_PASSWORD` | B | — |

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `spctl` shows "rejected" | Notarization failed — check `xcrun notarytool log <submission-id>` for details |
| "resource fork" / `._` file errors | Run `xattr -cr Pharos.app` and `find Pharos.app -name '._*' -delete` before re-signing |
| Keychain prompt during signing | Make sure the cert's private key has ACL permission for `/usr/bin/codesign` |
| Gatekeeper warning on launch | Ticket not stapled — re-run `xcrun stapler staple Pharos.app` |
| `com.apple.security.app-sandbox` error | Remove that key from `.build/entitlements/Pharos.entitlements` — Pharos must not be sandboxed |
