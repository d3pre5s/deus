# Upstream updates

Each Airlock fork has a dedicated `upstream-mirror` branch. The workflow
`.github/workflows/upstream-mainline.yml` runs daily at 06:37 UTC and can
also be run manually from the fork's default branch.

| Airlock fork | Upstream input |
| --- | --- |
| `deus-airlock` | `SagerNet/sing-box-for-apple:main` |
| `deus-airlock-core` | `SagerNet/sing-box:stable` |
| `deus-airlock-tun` | `SagerNet/sing-tun:main` |

The job pushes only to `upstream-mirror`. It uses full Git history when
the branch moves, a regular push and a readback check. Git rejects rewritten
history. Investigate a rejection and select a new reviewed baseline before
moving the mirror. The workflow uses the fork's own short-lived token and
does not check out or run upstream build code.

## Integrate a fix

1. Fetch `origin upstream-mirror` in each fork and compare it with the last
   accepted source tuple. Keep the apple client on `main` and core on
   `stable` unless an alpha upgrade is explicitly qualified.
2. Resolve sing-tun from the selected core's `go.mod`. It can lag the latest
   sing-tun mirror. Verify the Darwin patch on that precise revision, push it
   to the tun fork and replace it in core with the published Go module
   pseudo-version and checksums.
3. Build Libbox for macOS, then build the app with that Libbox and the pinned
   Swift packages. Run the launch daemon and policy tests and verify the
   effective bundle IDs. Keep integration commits on their own branches
   until the updated product passes acceptance.
4. Requalify the installed policy for changes to the provider, route/DNS
   handling, app rules or VPN lifecycle. Keep the previous signed build for
   rollback. Source mirrors have no role in distributing binaries.

The standalone Airlock updater does not consume upstream SagerNet packages.
In-app update delivery requires a separate Airlock release source, installer
identity validation and an upgrade test that preserves the app binding.

The template used for the three workflows is in
[`Tools/upstream-mirror.yml.in`](../Tools/upstream-mirror.yml.in). GitHub
runs the rendered workflow from each fork's default branch.
