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

## 2026-11-18 — signed local qualification

Built the arm64 Release archive with `AIRLOCK_ACCEPTANCE` enabled for the
standalone host. The local test build omits iCloud containers and multicast.
The development profiles authorize `packet-tunnel-provider`. The Developer ID
profiles authorize `packet-tunnel-provider-systemextension`. The installed
host and provider use the latter value, the same Team ID and App Group, and
their respective direct distribution profiles. Verified their entitlements and
the nested signatures after installation. The existing Swift suite passed all
14 tests.

Used the host's explicit `--airlock-acceptance bind PATH` action with a
signed test fixture. macOS accepted the per-app configuration. The host loaded
it again and matched the fixture's path, signing identifier, designated
requirement and on-demand settings. The `remove` action removed that
configuration and a separate `status` invocation confirmed its absence.

The first system-extension activation failed with `code signature invalid`.
Gatekeeper reported `Unnotarized Developer ID`. A standalone VLESS transport
probe reached the expected exit through the configured VPS. Claude Desktop,
Claude Code, spawned helpers and tunnel-loss enforcement still require a live
run with the activated Airlock provider.

### Notarized build and traffic results

Apple accepted the submitted archive. Xcode exported a stapled Developer ID
build. The installed copy passed strict nested signature verification, ticket
validation and Gatekeeper assessment. macOS activated the system extension.

**Isolation failed for a directly launched Claude Code CLI.** With its exact
rule loaded and the tunnel connected, the CLI sent packets over the physical
interface. Its child curl returned the ordinary public IPv4 address. During a
40-second suspension of the Airlock provider, curl still returned that address,
SSH received a server banner, and Git read the HEAD of a public repository.
Packet metadata linked the CLI, curl, SSH and Git's HTTPS helper to the
physical interface during suspension.

A separate selected fixture launched through Launch Services reached the
expected VPS exit before and after suspension and received no response during
suspension. The same fixture launched as a standalone executable exhibited
the CLI bypass. Desktop helper DNS packets appeared on the tunnel interface.
End-to-end Desktop traffic, IPv6, and a separate upstream-only failure remain
unverified. The temporary acceptance policy was removed and its absence
confirmed. The notarized extension remains enabled. An active tunnel or a
successful policy readback must not be presented as proof of CLI protection.

### Terminal launcher acceptance

The local terminal launcher now enforces a loopback-only socket policy for
the real CLI and its descendants. The provider terminates the authenticated
local TLS proxy and connects through a fixed-peer, user-level TCP relay.
Testing through the ordinary command in a new zsh confirmed the expected VPS
exit, an API response, SSH transport and a public Git HEAD. Unloading the
relay closed an established SSH channel and prevented all four probes from
reaching their destinations. The outside control stayed online. All four
probes recovered after reloading the relay. Raw IPv4 UDP and IPv6 TCP/UDP
attempts from inside returned EPERM across the three phases. This result
applies to the launcher path. See [terminal isolation](../Tools/CLI/README.md).

### Native Claude Desktop binding, 2026-11-19

The signed acceptance host now extends a matching existing policy in place.
It checks the prior identities and on-demand settings before saving, then reloads
the policy. The CLI startup command supplies both the vendor CLI and
`/Applications/Claude.app` when binding and starting the stored profile.

On the development Mac, the new Xcode archive and the installed notarized host
both read back two exact rules. The provider reported connected after the save.
The local CLI inheritance regression passed. Opening the native Claude app
produced established connections from Claude and Claude Helper on utun4, whose
IPv4 address matched the Airlock TUN profile. The extension and installed host
binary were unchanged. These observations establish a binding and sampled GUI
traffic. A local Code-session probe is required for egress IP and outage results.

The user confirmed that Claude Desktop opened and that the Code tab required
a paid subscription. No local Code session started. In a relay interruption
with Desktop open, the gateway probe reported the expected Spanish exit, then
no network, then the expected exit again. A separate Mac probe stayed online
with a different exit. Sampled Desktop TCP sockets on utun4 disappeared at
interruption. The early recovery sample had no Desktop socket; only gateway
recovery was confirmed. The relay was restored and both rules were read back.

## 2026-11-20 — audit fixes, build 13

The release candidate is 1.14.4 (13). The installed 1.14.4 (12) and its VPN
preferences were left in place. The transport exception approved for the
terminal launcher is recorded in the [MVP contract](superpowers/specs/2026-11-18-deus-airlock.md).

| Audit item | Evidence from this revision |
| --- | --- |
| P1 · GUI Stop | A replay of the actual Stop handler on an in-memory Apple per-app manager retained its app rule and unconditional On Demand. Before the change the same handler cleared On Demand. Tests cover both manager orderings, a renamed owned profile, a foreign profile and ambiguous ownership. GUI Start also checks the current signed target paths. macOS may reconnect a stopped transport on demand. |
| P1 · Protected transport | Start, automatic recovery and reload enforce the same closed schema. DNS and the final route use the single VLESS/REALITY peer. Ordinary imports cannot add a proxy. Explicit CLI setup pins its two local ports and the configuration digest. The actual pinned HTTP/TLS inbound returned 407 without credentials and 200 with them, then carried data to a temporary local backend. The embedded Libbox accepted the native and CLI fixtures. |
| P1 · Recovery | The provider saves a private snapshot per VPN profile after Libbox accepts the candidate. Failed startup, failed reload, failed disk commit, two profiles and an unowned legacy plist have separate tests. After upgrade the first successful explicit start seeds the snapshot used by GUI Start and On Demand. |
| P1 · Distribution | The release bundle contains the versioned terminal tools. Packaging tests cover clean setup, migration from the documented build-12 layout, repeat setup and rollback. Registration and preference failure cases use test doubles. System extension approval, saving a profile and installation of a signed PKG still need a real deployment. |
| P2 · Vendor updates | Rebinding the stable Claude CLI link checks the vendor signing requirement and reads back overlapping old and new exact rules before retiring the old path. Tests rotate a temporary signed executable and exercise stale saves and failed readback. |
| P2 · Outage diagnosis | A curl timeout or reset through another endpoint is inconclusive. A qualifying failure includes the expected loopback port, TLS verification and CONNECT result. Fixtures cover wrong ports, certificate errors, authentication failures and upstream proxy failures. |
| P2 · CLI-only selection | A fresh terminal setup can select just the vendor CLI. Existing saved selections survive migration. A previously selected missing Desktop or helper stops the operation. |

**Requirements still awaiting system acceptance.** R01–R08 require packet
captures from the installed candidate for CLI and Desktop, independent launch
paths, protocol coverage, pre-existing sockets, reboot, sleep, network changes
and competing VPNs. Spain-side loss with a reachable VPS remains a separate
server-side test. R09–R11 have local update, rollback and narrow-loopback
regressions. Runtime coverage on the installed candidate remains open.
Under R12/R13, a matching binding and a connected transport do not establish
traffic coverage. The Claude API diagnostic also accepts a generic connection error,
so its individual result cannot establish the packet path. The current CLI
credential store still uses private files.
R16 (new independent executables in selected directories) failed earlier
qualification and remains open. R14, R15 and R17 are later-stage scope.

**Verification on arm64 macOS.** SwiftPM passed 41 tests. Python passed all
25 CLI tests and all 15 build/distribution tests, including the macOS Seatbelt
and SSH fixtures. Xcode compiled both production Release and the qualification
variant from the pinned package graph with signing disabled. The production
app's component and product PKG were built and expanded. Both package
receipts report 1.14.4.13, the host and provider both report build 13, and the
provider Mach service includes this build number. The extracted resources
passed the shipping manifest check. The production executable routed the
control flag and rejected the qualification-only flag. Strict SwiftLint,
ShellCheck, plist/XML checks, Git whitespace checks and a redacted Gitleaks
scan passed. The pinned core built with gVisor and the Darwin sing-tun race
tests and go vet passed. The installed app still reports build 12.

### Developer ID candidate, 2026-11-20

The arm64 production archive for 1.14.4 (13) was built from
`1ff171a56982626abaac346191aa8511a71048c9`. The macOS toolbar now enables
Stop and Start when Airlock has a bound per-app profile and the ordinary SFM
profile library is empty. The four combinations of product and library state
passed the toolbar check. The final revision passed 41 Swift, 25 CLI and
15 distribution tests.

The app and system extension passed strict Developer ID signature,
entitlement and provisioning checks. The production executable rejected the
qualification-only command, and the bundled terminal tools matched the
shipping manifest. A locally saved ZIP was extracted and checked again.
Both code signature hashes matched the signed archive.
Its SHA-256 is `f1c99bd2bfacf24fc8b4e5f23b92c8384c96aa955ab6cc35b902cf58e6e9c457`.

At this checkpoint the Mac was running build 12. Its signed, notarized
rollback copy was verified before deployment. The Apple submission was held
for confirmation. The live GUI Stop/Start and the server-side Spain outage
had no build-13 result at this point.

### Spain route interruption on installed build 12, 2026-11-20

The operator coordinated a loss of the VPS route to the home network in
Spain. The owner confirmed restoration. A real Claude Code Setup hook on
the installed 1.14.4 (12) sampled HTTPS through the terminal launcher. It
compared the observed exit with the previously recorded home IPv4 and ES
country code. The local Airlock relay accepted a connection after recovery.

| Client observation | Result |
| --- | --- |
| Before interruption | 14 fresh requests returned the expected home exit. A second curl process repeatedly received HTTP 200 on one connection. |
| During interruption | 35 fresh requests received a transport failure through the TLS-verified local proxy. From the first to the last refusal, all 37 independent checks reached both the configured VPS TCP port and the trace service via the ordinary Mac connection. |
| After restoration | The first fresh home response arrived 160 seconds after the first refusal. All 10 recovery requests matched the same home exit. The second curl process resumed HTTP 200 on a new connection. A separate SSH probe received the public server banner. |

No sampled protected response reported an alternate exit. These observations
cover the client HTTPS path on build 12. Verifying the VPS rule for ordinary
WAN egress still requires server-side counters or a scoped capture. Build 13
GUI Stop/Start and per-app and On Demand readback remain separate.

### Installed build 13 GUI Stop/Start, 2026-11-20

Apple notarized the Developer ID archive built from `1ff171a`. The local
installation passed stapled-ticket and Gatekeeper checks. macOS activated
the matching 1.14.4 (13) system extension without requiring a new approval.
The terminal migration read back the same three selected executable
identities, and the first successful start populated the profile snapshot.

The owner clicked Stop and then Start in the macOS toolbar. The signed
host read the saved policy from macOS in three distinct states.

| Checkpoint | Tunnel | Exact per-app rules | On Demand |
| --- | --- | ---: | --- |
| Before Stop | Connected | 3 | Enabled, unconditional Connect |
| After Stop | Disconnected | 3 | Enabled, unconditional Connect |
| After Start | Connected | 3 | Enabled, unconditional Connect |

The paths and signing requirements matched at all three checkpoints. After
Start, the protected terminal launcher reached the expected Spanish exit,
read Git HEAD, received SSH banners in both tests, and got the expected API
response to an invalid test key. This run covers the installed GUI cycle
and normal terminal connectivity. Lifecycle, outage and Desktop gates are
tracked separately.

### Local relay loss on installed build 13, 2026-11-20

The check stopped only the user LaunchAgent for the local Airlock relay.
It observed the real terminal Claude Code launcher and its descendants on
1.14.4 (13), with a separate Mac process as a control. The signed host
reported the VPN connected while the relay port was unavailable.

- Before the interruption, curl and a new helper executed by the protected
  shell reported the expected IPv4 and country code. SSH banners and Git
  HEAD were reachable. A second SSH stream had already received its banner.
- During the interruption, the established SSH stream reached EOF. Fresh
  HTTPS, SSH and Git requests in the protected tree failed. The kernel
  denied direct IPv4 and IPv6 TCP and UDP socket probes in the protected
  tree. The independent Mac control could still reach the internet via a
  distinct exit.
- The relay returned after 6.7 seconds. Protected requests recovered on the
  same Spanish exit. The signed host read back the original three exact
  per-app rules and unconditional On Demand, with the same policy digest
  as after GUI Start.

These results cover the terminal launch path and the probes above. DNS
and interface-level leakage still need packet evidence. Claude Desktop and
independent executables have separate acceptance cases.
