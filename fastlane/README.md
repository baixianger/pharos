fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac bump_build

```sh
[bundle exec] fastlane mac bump_build
```

Set BUILD_NUMBER in version.env to the current git commit count. Mirrors the hetznerly convention (build = commit count, always monotonically increasing on the main branch).

### mac icon

```sh
[bundle exec] fastlane mac icon
```

Generate Icon.icns from assets/icon-source.png via Scripts/make_icns.sh. Requires sips and iconutil (both bundled with macOS).

### mac build

```sh
[bundle exec] fastlane mac build
```

Build Pharos.app via Scripts/package_app.sh (release config). Ad-hoc signs if APP_IDENTITY is unset; Developer ID signs when set. Pass APP_IDENTITY env var to produce a distributable bundle.

### mac sign_and_notarize

```sh
[bundle exec] fastlane mac sign_and_notarize
```

Developer ID sign, notarize, staple, and zip Pharos.app via Scripts/sign-and-notarize.sh. Requires env vars:
  APP_IDENTITY          — 'Developer ID Application: Your Name (TN7ZDD72P2)'
  NOTARYTOOL_PROFILE    — keychain profile name (Option A, recommended)
  — OR —
  NOTARYTOOL_APPLE_ID   — Apple ID email
  NOTARYTOOL_TEAM_ID    — defaults to TN7ZDD72P2
  NOTARYTOOL_APP_PASSWORD — app-specific password from appleid.apple.com

### mac appcast

```sh
[bundle exec] fastlane mac appcast
```

Generate the Sparkle appcast (appcast.xml). Calls Sparkle's generate_appcast tool if it can be found in the SPM cache, otherwise prints the manual instructions from docs/SPARKLE.md. Expects the notarized zip to already exist (run `notarize` first).

### mac dmg

```sh
[bundle exec] fastlane mac dmg
```

Build a styled Pharos-<version>.dmg (branded background + drag-to-Applications layout) via Scripts/make_dmg.sh. Expects Pharos.app to exist (run build / sign_and_notarize first). For distribution the DMG should also be codesigned + notarized + stapled (see docs/RELEASE.md).

### mac release

```sh
[bundle exec] fastlane mac release
```

Full release orchestration: bump_build → build → sign_and_notarize → appcast → create GitHub release (gh release create) attaching the notarized zip and appcast.xml with notes from CHANGELOG.md. Reads MARKETING_VERSION from version.env. Requires the same env vars as the `notarize` lane plus `gh` (GitHub CLI) to be authenticated.

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
