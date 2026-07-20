fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios bootstrap

```sh
[bundle exec] fastlane ios bootstrap
```

Register the App ID in the Developer Portal and sync match profiles. Idempotent — re-run after editing entitlements. Only needed for the TestFlight/App Store path; `device_install` uses automatic signing and does not require this.

### ios fix_icloud_capability

```sh
[bundle exec] fastlane ios fix_icloud_capability
```

Enable the iCloud capability on the App ID (the app entitles ubiquity-kvstore for multi-machine sync) and force-regenerate the appstore match profile so it embeds the entitlement. Idempotent.

### ios certs

```sh
[bundle exec] fastlane ios certs
```

Sync App Store certificates & provisioning profiles via match

### ios bump_build

```sh
[bundle exec] fastlane ios bump_build
```

Bump build number to the current git commit count

### ios device_install

```sh
[bundle exec] fastlane ios device_install
```

Build a development-signed .ipa and install it onto a paired iPhone/iPad via Xcode's devicectl. Pass `udid:` to target a specific device; defaults to the first paired iOS device. Uses automatic signing (project.yml sets CODE_SIGN_STYLE=Automatic) — no match needed, just sign into Xcode → Settings → Accounts once and enable Developer Mode on the device.

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build Release and upload to TestFlight (internal testing needs no review).

### ios create_asc_app

```sh
[bundle exec] fastlane ios create_asc_app
```

Create the App Store Connect record (one-time). Needed before the first TestFlight upload if the app doesn't yet exist in ASC.

### ios verify_asc_app

```sh
[bundle exec] fastlane ios verify_asc_app
```

Read-only: confirm the ASC record exists; print its name and versions.

### ios audit_listing

```sh
[bundle exec] fastlane ios audit_listing
```

Read-only: audit the edit version's staged listing (metadata fields + screenshot counts).

### ios reset_screenshots

```sh
[bundle exec] fastlane ios reset_screenshots
```

Purge every screenshot from the edit version's sets and re-upload the local en-US set exactly once. Works around deliver's verify-loop race against ASC's eventual consistency, which duplicates uploads.

### ios list_asc_users

```sh
[bundle exec] fastlane ios list_asc_users
```

List ASC team members. Internal TestFlight testers MUST be ASC team members.

### ios ensure_beta_group

```sh
[bundle exec] fastlane ios ensure_beta_group
```

Create a TestFlight Internal Testing group (idempotent). `name:` default 'Internal'.

### ios invite_to_group

```sh
[bundle exec] fastlane ios invite_to_group
```

Create + assign a TestFlight tester to a group in one call. Usage: fastlane invite_to_group email:you@example.com group:Internal

### ios set_price_free

```sh
[bundle exec] fastlane ios set_price_free
```

Set the app's price to Free (one-time). The FREE price point id must be looked up dynamically — the old USA_F sentinel is dead.

### ios ensure_category

```sh
[bundle exec] fastlane ios ensure_category
```

Print current categories; set primary to DEVELOPER_TOOLS if unset.

### ios prepare_version_attrs

```sh
[bundle exec] fastlane ios prepare_version_attrs
```

Patch the edit version: usesIdfa=false and releaseType=MANUAL. deliver's submission_information does NOT set the version's usesIdfa attribute, and MANUAL guarantees approval never auto-ships.

### ios set_age_rating

```sh
[bundle exec] fastlane ios set_age_rating
```

Set the full age-rating declaration (everything NONE/false — Pharos is a single-user developer tool; its chat is with the owner's own agents, not user-to-user). PATCHes at the appInfo level: the version-level path errors, and fastlane 2.232's rating_config.json predates the 2025 socialMedia fields.

### ios select_build

```sh
[bundle exec] fastlane ios select_build
```

Attach the latest VALID processed build to the edit version. Pharos uploads via beta, so fastlane#19633 (Xcode-Cloud builds only) doesn't apply.

### ios why_blocked

```sh
[bundle exec] fastlane ios why_blocked
```

Explain why the current version is not submittable — dumps the editable version's state, review attributes, and attached build.

### ios submit_review_v2

```sh
[bundle exec] fastlane ios submit_review_v2
```

Submit the current version for review via the modern reviewSubmissions flow (fastlane's submit_for_review posts to a removed endpoint). HUMAN GATE: only run when the human explicitly says submit.

### ios stage_listing

```sh
[bundle exec] fastlane ios stage_listing
```

Upload metadata to App Store Connect, leaving the listing in 'Prepare for Submission' (no review submission). Personal app — see the note above.

### ios release

```sh
[bundle exec] fastlane ios release
```

stage_listing + submit for review (personal app — usually not needed; see the note above stage_listing).

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
