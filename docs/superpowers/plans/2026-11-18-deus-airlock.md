# Deus Airlock implementation plan

> **For agentic workers:** Use superpowers:executing-plans task by task.

**Goal:** An independently buildable Deus Airlock with the Darwin fix and a safe,
testable path to app-and-helper isolation.

**Architecture:** SFM macOS wrapper, Libbox from deus-airlock-core, patched sing-tun.
OS policy is separate from transport lifecycle. An offline policy candidate
does not install a VPN or claim enforcement.

**Tech Stack:** Swift, NetworkExtension, Security, Go, Xcode 26.6.

**Spec:** [Product contract](../specs/2026-11-18-deus-airlock.md).

## Constraints and rulings

- Preserve old dirty source snapshots and existing PR #101.
- Work in separate `codex/deus-airlock` branches. Do not commit the parent
  folder, which contains private research and configurations.
- Keep upstream GPL notices; no personal signing credentials in Git.
- Local quality WORKFLOW.md and SKILLS.md referenced by owner instructions
  are absent. Use actual repository checks and record unavailable checks.
- Do not activate experimental policies, remove VPNs or delete apps during
  offline preparation. Installation/enforcement gates stay explicit.

## Review focus

- Helper launched outside the selected app must not be captured globally.
- Same filename with another signature/path must not become trusted.
- Partial configuration and failed policy writes must not erase bindings.
- Missing or stale runtime evidence must not display a protected state.
- Imports and DNS must not open a direct route or local control listener.

## Task 1 — reproducible Darwin transport

Files: `deus-airlock-tun/tun_darwin*.go`, `deus-airlock-tun/internal/fdbased_darwin/*`,
`deus-airlock-core/go.mod`, `deus-airlock-core/go.sum`, build manifest in this repository.

- [x] Create own app/core forks and isolated compatible source branches.
- [ ] Copy existing regression tests before applying the compatible patch;
  record baseline failure, then run native and gVisor suites after patch.
- [ ] Build/test the full sing-tun package tree; separate IP-dependent tests
  from offline checks. Do not weaken tests to hide unavailable networking.
- [ ] Pin our exact sing-tun revision in core, install the pinned gomobile
  tools and build a macOS Libbox.xcframework.
- [ ] Record exact sources, toolchain and commands; preserve original source
  snapshots and patch tests.

## Task 2 — independent app build

Files: `sing-box.xcodeproj/project.pbxproj`, `Configuration/Airlock.xcconfig`,
`Tools/`, `README.md`, `docs/build.md`.

- [ ] Restore locked Swift packages and Runestone submodule.
- [ ] Set own bundle base `io.github.d3pre5s.deusairlock`, app name Deus Airlock and separate
  system-extension identity. Keep signing inputs in ignored local config.
- [ ] Build unsigned first; inspect all build diagnostics. Prepare signed
  build with the owner's installed Developer ID, without exporting its key.
- [ ] Verify profiles, entitlements and nested code before installation.

## Task 3 — public per-app qualification

Files: `Library/Isolation/`, `Tests/Isolation/`, `Tools/`.

- [ ] Start from meaningful offline tests: exact identity/path, nil helper
  scope, refusal of empty/malformed rules and round-trip policy readback.
- [ ] Build a minimal explicit diagnostic entry point using public
  `NETunnelProviderManager.forPerAppVPN()` and `NEAppRule` APIs. No private
  configuration APIs; no automatic application on launch.
- [ ] Prepare probes and a reversible installation plan. Only after runtime
  qualification connect it to the normal app lifecycle and protected status.
- [ ] Execute acceptance gates 3–5 after live testing is resumed. If denied
  by macOS, record the actual error and investigate a supported deployment.

## Task 4 — strict policy and migration

- [ ] Add strict single-server config generation/validation with tests for
  DNS direct fallback, unsupported transport and control listeners.
- [ ] Implement inventory/update handling and retained policy on disconnect
  only against the qualified backend; test failures before happy paths.
- [ ] Reuse existing SFM UI for coverage and diagnostics; perform rendered
  verification and independent review before calling the UI complete.
- [ ] Review the whole branch, resolve findings, repeat affected checks.
- [ ] Prepare actual uninstall/rollback steps after replacement acceptance.

Progress and actual evidence live in [execution.md](../../execution.md).
