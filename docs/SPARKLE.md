# Pharos — Sparkle Auto-Update Guide

Pharos uses [Sparkle 2](https://sparkle-project.org) for automatic updates distributed
over a direct-download appcast.  This document covers everything needed to go from a
fresh developer checkout to shipping an update.

---

## 1. Generate EdDSA signing keys (one-time)

Sparkle signs update packages with an EdDSA key pair.  The private key is stored in your
macOS Keychain; the public key goes in `Info.plist` so Sparkle can verify downloads.

```sh
# From the checked-out Sparkle source (or the resolved SPM cache)
# SPM cache location on macOS:
SPARKLE_CACHE=~/.cache/org.swift.swiftpm/repositories/Sparkle-*.git
# or, more reliably:
SPARKLE_CACHE=$(swift package show-dependencies --format json \
  --package-path /Users/baixianger/personal/pharos \
  | python3 -c "import sys,json; \
    deps=json.load(sys.stdin)['dependencies']; \
    [print(d['path']) for d in deps if 'sparkle' in d['name'].lower()]")

"$SPARKLE_CACHE/bin/generate_keys"
```

This prints a **public key** and stores the private key in your login Keychain under the
name `Sparkle Key` (tied to your app's bundle ID).  Copy the public key string.

### Paste the public key into Info.plist

In `Scripts/package_app.sh`, find the placeholder:

```xml
<key>SUPublicEDKey</key><string></string>
```

Replace the empty string with the key generate_keys printed, e.g.:

```xml
<key>SUPublicEDKey</key><string>AAAA...your_public_key_here...==</string>
```

Commit the updated `package_app.sh`.  **Never commit the private key.**

---

## 2. Build a release archive

After bumping `version.env`:

```sh
export APP_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export NOTARYTOOL_PROFILE="pharos-notary"
Scripts/sign-and-notarize.sh
```

This produces `Pharos-<version>.zip` (notarized + stapled).

---

## 3. Sign the update with Sparkle's `sign_update` tool

```sh
# sign_update lives next to generate_keys in the Sparkle package
"$SPARKLE_CACHE/bin/sign_update" Pharos-<version>.zip
```

It prints an `edSignature` value and the file length.  You'll need both for the appcast.

---

## 4. Build the appcast

The appcast is an RSS-like XML file that Sparkle polls.  Create or update it at the URL
set in `SUFeedURL` (`https://me.pai/pharos/appcast.xml`).

Minimal `appcast.xml` template:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Pharos</title>
    <link>https://me.pai/pharos</link>
    <description>Pharos changelog</description>
    <language>en</language>
    <item>
      <title>Version 1.2.0</title>
      <pubDate>Thu, 19 Jun 2026 00:00:00 +0000</pubDate>
      <sparkle:version>42</sparkle:version>                 <!-- CFBundleVersion / BUILD_NUMBER -->
      <sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
      <enclosure
        url="https://me.pai/pharos/Pharos-1.2.0.zip"
        length="12345678"                                   <!-- byte length from sign_update -->
        type="application/octet-stream"
        sparkle:edSignature="AAAA...signature_from_sign_update...==" />
    </item>
  </channel>
</rss>
```

If `Scripts/make_appcast.sh` exists in this repo, run it instead — it generates the XML
automatically from the signed zip.

---

## 5. Host the appcast and zip

Upload both files to the server at `https://me.pai/pharos/`:

| Path | Contents |
|---|---|
| `/pharos/appcast.xml` | The appcast (must be served with `Content-Type: text/xml` or `application/rss+xml`) |
| `/pharos/Pharos-<version>.zip` | The signed, notarized release zip |

Sparkle checks `SUFeedURL` on launch and on "Check for Updates…".  It downloads the
enclosure URL only when the user approves an update.

---

## 6. Verify the update flow

1. Install the *previous* version of Pharos.
2. Put the new version's zip + appcast on the server.
3. Launch the old version, choose **Pharos → Check for Updates…**.
4. Sparkle should detect the newer `sparkle:version` and offer to install it.

---

## Runtime embedding note

SwiftPM resolves Sparkle as a **binary XCFramework** and copies the correct architecture
slice as `Sparkle.framework` into the build products directory
(`.build/<arch>-apple-macosx/debug|release/`).

`Scripts/package_app.sh` picks this up automatically via the existing framework-embedding
loop.  The `sign_frameworks` function signs Sparkle's nested bundles
(Updater.app, Downloader.xpc) before the outer framework, satisfying Apple's nested-code
signing requirements.

**No manual framework-copy step is needed.**
