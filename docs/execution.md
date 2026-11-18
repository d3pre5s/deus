# Execution evidence

## 2026-11-18 — fork bootstrap

Authorization: owner requested own fork/software, including Claude helpers,
fail-closed behavior and later removal of redundant networking software.
The existing design is retained with the helper requirement clarified.

Created `d3pre5s/deus` from SagerNet/sing-box-for-apple and
`d3pre5s/deus-core` from SagerNet/sing-box. Existing `d3pre5s/sing-tun` is
the dependency fork. New independent local checkouts use
`codex/deus-isolation`; old dirty checkouts and PR #101 are untouched.

Initial source tuple:

| Component | Commit |
|---|---|
| Apple wrapper | e232aaf22d6d68773196ffc8e6e79684a6be717c |
| sing-box | 7054cac5124465ffdb145870d7c01885566711b1 |
| sing-tun compatible base | bca4bf029237e444104626bb25f947dda90b06b5 |

Host tools: Xcode 26.6 (17F113), Go 1.27.1 darwin/arm64.

## Local qualification

- The compatible sing-tun patch was applied to the isolated checkout. The
  pre-patch regression suite failed to compile for missing `packetHeaderSize`.
  After the patch, the native and gVisor/race root package passed. Both
  whole-tree runs failed in `ping/TestIsClosed` and `ping/TestPing` because
  the runner denies IP sockets. The privileged kernel test was skipped.
- `go vet -tags with_gvisor ./...` and Darwin amd64 test compilation passed.
  Built macOS Libbox for arm64 and x86_64. The local core still uses the
  sibling checkout while the public fork revision is pending.
- SwiftPM passed 14 tests for app identity, per-app rule preparation, the
  in-memory manager and fork deep links. The inspector read the installed
  Claude signature without applying a profile or starting a tunnel.
- Review flagged deep links, launchd identity and packaging paths that still
  pointed at SFM. Fixed their configuration, ran three launchd generator
  tests and checked the packaging commands with `make -n`.
- Xcode package resolution passed with the original lockfile. The full app
  build stopped at `permissionDenied` under nested sandboxing. Signed app
  build and runtime policy tests remain pending. No VPN or app was installed
  or removed.

## 2026-11-18 — Deus Airlock naming

The app and Xcode scheme are now **Deus Airlock**. The bundle base is
`io.github.d3pre5s.deusairlock` and the app URL scheme is `deus-airlock`.
The installer receipt, extension, helper and App Group derive from the new
base. No Apple Developer identifiers or provisioning profiles were created.

| Local checkout | Previous GitHub origin | Current GitHub origin |
| --- | --- | --- |
| `deus-airlock` | `d3pre5s/deus` | `d3pre5s/deus-airlock` |
| `deus-airlock-core` | `d3pre5s/deus-core` | `d3pre5s/deus-airlock-core` |
| `deus-airlock-tun` | `d3pre5s/sing-tun` | `d3pre5s/deus-airlock-tun` |

All three local branches are `codex/deus-airlock`. The upstream PR #101
continues to use its existing `codex/darwin-process-uuid` source branch. Core
resolves its sing-tun override from the renamed sibling checkout. The Go
import paths still follow the original modules.

Xcode reported the new app name, app bundle ID and URL scheme. The 14 Swift
tests and 3 launch daemon tests passed. The packaging checks used a dry run.

GitHub renamed all three repositories in place and the local origins now
use their current URLs. The original fork IDs were preserved. PR #101 was
verified open at the same source branch and head commit after the rename.

## 2026-11-18 — upstream integration

- SFM `main` at `c9cea9bf1187ea9031dc380be344c10328f57dc4` brings the 1.14.4
  fixes. Resolved the Share Extension conflict against upstream's macOS
  handler. Cache/load/install paths for upstream package updates are disabled
  in the Airlock app. Host, tunnel and Share Extension share version 1.14.4
  and build number 10.
- Core `stable` at `f4e75a44e1d251848bb61b494f47d49032c75523` selects
  sing-tun `294efeca1ba7258c28c13872c0d3fce5a3594f5b`. Layered our Darwin
  patch as `26bd19a00934d5fb14cff55ab302d2e0dad2ac0b` and pinned the public
  Go module in Airlock core `f8754593405ac10105e2538a64eaada578f153e5`.
- GitHub Actions mirrors ran successfully for all three forks. Their branch
  SHAs matched the upstream branches just listed. See [upstream updates](upstream.md).
- The native Darwin/gVisor race test and Go vet passed. SwiftPM passed 14
  tests and the launch daemon generator passed 3. Libbox built with the
  public module pin for arm64 and x86_64. Xcode built the unsigned arm64 app
  with its system and share extensions. No app or profile was installed and
  no live traffic acceptance was attempted.
