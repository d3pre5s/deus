# Deus Airlock for macOS

Deus Airlock is an independent GPL-3.0-or-later fork of sing-box-for-apple. Its
network engine is the Deus Airlock fork of sing-box with the Darwin process-UUID
utun framing fix from our sing-tun fork. Upstream copyright stays intact.

## Product contract

- Selected Claude applications and helpers they launch must use the selected
  VPS or have no network. The same system helper launched by another app
  must retain that app's normal network policy.
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

## First release boundary

Airlock builds on the SFM macOS client and a pinned sing-box/Libbox and
sing-tun pair. It has no runtime dependency on ProxyBridge, LuLu, FreeSnitch
or FireWally. The product replaces ProxyBridge only for the protected Claude
workflow. A general-purpose per-program proxy, ProxyBridge rule import,
machine-wide firewall, and filesystem sandbox are outside this release.

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
6. Back up existing configurations and test rollback before uninstalling
   redundant software. Unrelated VPNs and remote access stay available.

The owner's previous pause on live network failure experiments is retained
until explicitly resumed. Development, source forks, local offline checks
and preparing reviewable artifacts are authorized now.
