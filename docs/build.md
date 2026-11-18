# Build Deus Airlock

Deus Airlock is a development fork. Building or signing it does not establish network
isolation. The runtime acceptance gates in the product spec remain required.

## Sources

Use this app checkout and [deus-airlock-core](https://github.com/d3pre5s/deus-airlock-core)
at `f8754593405ac10105e2538a64eaada578f153e5`. Core fetches the patched
[deus-airlock-tun](https://github.com/d3pre5s/deus-airlock-tun) module at
`v0.9.7-0.20261118175918-26bd19a00934` from its Go module cache or proxy.
The tun remote commit and both checksums are fixed by core's module files.
See [upstream updates](upstream.md) for the process to advance this tuple.

```sh
git submodule update --init --recursive
```

Run this in `deus-airlock`. Runestone is pinned by the submodule commit and Swift
packages by the existing Xcode `Package.resolved`. Do not update the package
graph to fix a missing download.

## Offline policy checks

```sh
swift test
```

The Swift package compiles the same `Library/Isolation` files included in the
Xcode Library target. Its tests prepare rules only; they never install a VPN.
For a restricted build runner, set scratch/cache directories and keep source
read-only, host secrets inaccessible and IP networking denied. If nesting
SwiftPM's manifest sandbox is unavailable, `--disable-sandbox` must only be
used inside that outer sandbox, not to remove isolation of test execution.

## Libbox

In `deus-airlock-core`, fetch the upstream version tag used by the builder
and prepare the module graph before building:

```sh
git fetch --no-tags https://github.com/SagerNet/sing-box.git refs/tags/v1.14.4:refs/tags/v1.14.4
go mod download all
go install github.com/sagernet/gomobile/cmd/gomobile github.com/sagernet/gomobile/cmd/gobind
go run ./cmd/internal/build_libbox -target apple -platform macos
```

These commands use gomobile pinned by the core's go.mod. Do not install its
latest version. Copy the resulting `Libbox.xcframework` into the `deus-airlock` root;
the upstream builder's automatic destination is named `sing-box-for-apple`
and does not refer to this fork. The framework stays out of Git.

## macOS app

```sh
xcodebuild -resolvePackageDependencies -project sing-box.xcodeproj -scheme "Deus Airlock" -onlyUsePackageVersionsFromResolvedFile
xcodebuild build -project sing-box.xcodeproj -scheme "Deus Airlock" -configuration Debug -destination 'generic/platform=macOS' -xcconfig Configuration/Airlock.xcconfig CODE_SIGNING_ALLOWED=NO
```

This first build is unsigned and is not installable as a working Network
Extension. `Deus Airlock.app` has a separate bundle base `io.github.d3pre5s.deusairlock`;
it must not replace the installed official SFM.

For a signed build, put the actual team and profile names in the ignored
`Configuration/Local.xcconfig`:

```xcconfig
DEUS_DEVELOPMENT_TEAM = YOUR_TEAM_ID
DEUS_APP_PROFILE = YOUR_DEUS_APP_PROFILE
DEUS_EXTENSION_PROFILE = YOUR_DEUS_EXTENSION_PROFILE
```

Create identifiers/profiles for `.standalone` and `.system` with the matching
Network Extension entitlement `packet-tunnel-provider-systemextension`,
system-extension installation on the host and a consistent App Group. Check
embedded share/helper targets as well. Current inherited iCloud capabilities
also require matching configuration; they have not been declared available
merely by changing the bundle base.

For `make export_macos_standalone_*`, copy `SFM.System/Export.plist` to the
ignored `Configuration/Export.local.plist` and replace the two placeholders
with the exact profile names for the app and extension. The host bundle and
share extension use the `DEUS_URL_SCHEME` project build setting. The signed
build renders its launch daemon from the effective bundle base and App Group.

Use the installed Developer ID identity with its private key. A certificate
alone is insufficient. Do not put `.p12`, provisioning files, credentials or
real server configurations in this public fork. Verify nested signatures,
provisioning entitlements, timestamp/hardened runtime and notarization before
distribution. Only then proceed to the separate live acceptance plan.

### Local qualification archive

After building Libbox above, use the dedicated qualification entitlements and
the developer team that owns the app and system extension identifiers:

```sh
xcodebuild archive -project sing-box.xcodeproj -scheme "Deus Airlock" \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$PWD/build/Airlock.xcarchive" \
  -xcconfig Configuration/Qualification.xcconfig \
  -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64 \
  AIRLOCK_TEAM_ID="$AIRLOCK_TEAM_ID"
```

This creates the Apple Development archive for local qualification. Developer
ID signing, direct-distribution profiles, notarization and ticket validation
are still required before installing the distribution build.
