# Deus Airlock for macOS

Deus Airlock is an independent GPL-3.0-or-later fork of sing-box-for-apple. Its
network engine is the Deus Airlock fork of sing-box with the Darwin process-UUID
utun framing fix from our sing-tun fork. Upstream copyright stays intact.

## MVP contract

- Selected Claude applications and their covered helpers use the selected
  VPS or have no network. Other applications keep their existing access.
  The same system helper launched outside a selected app retains that app's
  own policy. Airlock reports which launch paths have been verified.
- The OS per-app binding must survive closing the UI and stopping or crashing
  the transport. Do not turn loss of connectivity into direct fallback.
- DNS, IPv4, IPv6, UDP/QUIC, existing connections and new connections are in
  scope. A successful IP check alone is not acceptance.
- Directory inventory is not recursive OS enforcement. A new executable,
  external interpreter, symlink or IPC service remains unverified until its
  actual launch path is qualified. Preserve the recursive-directory goal;
  do not silently substitute an initial list of binaries.
- Do not modify Claude signatures, disable SIP, or deploy private
  NEConfiguration/SCPreferences APIs. Use the public per-app manager first.
- Keep the app alongside existing VPNs until tested. Remove redundant apps
  only during a verified migration with a working rollback.
- No green protection claim based only on a running tunnel or saved settings.
  Evidence must match the installed policy, identities, build and OS.

## MVP boundary

Airlock builds on the SFM macOS client and a pinned sing-box/Libbox and
sing-tun pair. The MVP has one protected routing mode backed by macOS per-app
VPN and one selected tunnel. Its acceptance does not depend on ProxyBridge,
LuLu or FireWally applying any policy on its behalf. General per-app proxy
profiles, a separate outbound firewall, ProxyBridge import and independent
block rules such as Photoshop stay outside the MVP. Existing firewall
rules stay in their current apps.

Start with signed macOS applications and their inherited helper scope using
`NEAppRule.matchTools == nil`. Use `NETunnelProviderManager.forPerAppVPN()`
and `appRules`; verify that save/reload retains these on the target Mac.
This public API is a candidate backend, not proof of runtime enforcement.

The transport accepts one explicitly selected VLESS/REALITY server. Its
configuration must not enable direct egress, automatic fallback, system
proxy, inbound proxy listeners or externally writable control APIs. Secrets
remain local. Filesystem/secrets isolation is a separate layer, not a claim
made by network routing.

The current implementation prepares and inspects rules offline. The inherited
SFM connection flow still creates an ordinary tunnel policy. The per-app
binding, kill switch, strict config and installer have their own acceptance
gates. Upstream app binaries and packages are not Airlock updates.

## Acceptance gates

1. Offline regression tests, reproducible Libbox and app builds.
2. Own bundle identifiers, provisioning and nested signatures verified.
3. Public per-app policy installation and readback; parent/helper/outsider
   capture evidence, with SIP enabled.
4. VPS loss, provider death, GUI exit, stop/restart, reboot, network change,
   DNS/IPv6/UDP and conflicting VPN tests. Packet loss in capture means
   inconclusive, not pass.
5. Actual Claude launch modes, updates and helper workflows. Qualify only
   tested cases. A proposed profile or unit test does not close this gate.
6. Confirm the protected app and helpers use the VPS when the tunnel is up,
   cannot egress directly when it is down, and leave a control app on its
   ordinary network. Measure without any third-party tool enforcing those
   results and prepare rollback before changing the live configuration.

The owner's previous pause on live network failure experiments is retained
until explicitly resumed. Development, source forks, local offline checks
and preparing reviewable artifacts are authorized now.

## After MVP

The broader product can combine tunnel routing with a general outbound
firewall and additional per-app routing rules. A macOS content filter is a
candidate for independent blocks such as Photoshop. Qualify it alongside
the tunnel and inventory existing app rules before migrating them.
[Apple deployment requirements](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
