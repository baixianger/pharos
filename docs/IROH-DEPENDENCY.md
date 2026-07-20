# Iroh dependency provenance

Pharos pins the official [n0-computer/iroh-ffi](https://github.com/n0-computer/iroh-ffi)
Swift package at `v1.1.0` rather than following a branch or a version range.

## Reviewed release

| Item | Pinned value |
|---|---|
| Release tag | `v1.1.0` |
| Git commit | `5e451092dba0c1a09ee83ff6e5be37b1152a5c58` |
| Upstream licenses | MIT OR Apache-2.0 |
| Swift product/module | `IrohLib` |
| Pharos ALPN | `me.pai.pharos/mesh/1` |

The upstream `Package.swift` pins its release XCFramework URL and checksum. The
same release exposes source-generated Swift bindings and a documented local
build path (`cargo make swift-xcframework`), so the binary can be rebuilt and
compared during a dependency update instead of being accepted as an opaque
unversioned download.

## Release artifacts

Checksums below are from the GitHub release metadata and were independently
checked for the Apple archive used by the initial integration.

| Artifact | SHA-256 |
|---|---|
| `IrohLib.xcframework.zip` | `ad46dadf09f9224157512992923562931ed60f252414230d50893a4d515c5776` |
| `libiroh-linux-aarch64.tar.gz` | `af76476388f9913edbd293cbb56882c4144a263f683af3695539eb773d6e9ed1` |
| `libiroh-linux-x86_64.tar.gz` | `8e7ae2ab8477a30a8766670f589a88c89be271c9c86f295d03c4ad0da136046d` |

The XCFramework contains `macos-arm64`, `ios-arm64`,
`ios-arm64_x86_64-simulator`, and `ios-arm64-maccatalyst`. Upstream does not
publish an Intel macOS slice; Pharos targets Apple Silicon.

## Current integration proof

On 2026-07-20, the iOS simulator app built and linked both arm64 and x86_64
against the exact `v1.1.0` checkout and the checksum-verified official
XCFramework. The verification used a disposable copy under `/tmp`, changed
only that copy's package reference from the exact remote pin to the local
checkout, and wrote DerivedData under the same temporary directory:

```sh
xcodebuild -project PharosMobile.xcodeproj -scheme PharosMobile \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/pharos-ios-local-iroh/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

The final result was `** BUILD SUCCEEDED **`, including a second incremental
build after the bounded-timeout implementation changed. This proves source and
binary compatibility without letting an Xcode network resolver obscure the
result. The production manifest remains the exact GitHub pin; remote package
resolution itself deadlocked in this local Xcode environment, so that resolver
path is not claimed as verified.

## Update gate

Before changing the exact version:

1. inspect the tag diff, changelog, licenses, and generated Swift API;
2. compare GitHub release digests with downloaded assets;
3. build the upstream XCFramework from the tag and inspect all expected slices;
4. run Pharos protocol, isolated direct-path, forced-relay, iOS simulator, and
   Linux bridge tests;
5. update the exact `Package.swift` pin, generated Xcode project resolution,
   and this file in the same commit. The repository intentionally ignores the
   root SwiftPM `Package.resolved`, so it is verification input rather than a
   tracked source of truth.

No Iroh integration test may read a Pharos production data directory, use a
configured Broker address, or reuse a persisted production identity. Tests use
fresh keys, loopback-only ephemeral ports, and relay-disabled endpoints unless
the test is an explicitly isolated forced-relay fixture.
