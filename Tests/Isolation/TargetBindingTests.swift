import Foundation
import NetworkExtension
import XCTest
@testable import DeusIsolation

final class TargetBindingTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/airlock-test")
    private var cli: String { home.appendingPathComponent(".local/bin/claude").path }
    private let desktop = "/Applications/Claude.app"

    private func identity(_ version: String, id: String = "com.anthropic.claude-code",
                          requirement: String = "identifier \"com.anthropic.claude-code\" and anchor apple generic") -> DeusAppIdentity {
        DeusAppIdentity(signingIdentifier: id, designatedRequirement: requirement,
                        executablePath: home.appendingPathComponent(".local/share/claude/versions/\(version)").path)
    }

    private func manager(_ identities: [DeusAppIdentity]) throws -> NETunnelProviderManager {
        try DeusPerAppPolicy(identities: identities).makeCandidate(providerBundleIdentifier: "com.example.extension")
    }

    func testVersionedUpdateVerifiesOverlapBeforeRetiringPreviousRule() throws {
        let old = identity("2.1.263")
        let new = identity("2.1.284")
        let installed = try manager([old])
        let previous = try AirlockTargetBinding(reading: installed, home: home)
        XCTAssertEqual(previous.paths, [cli], "Migrate the logical CLI slot even when the old file has already been removed")
        let requested = AirlockTargetBinding(slots: [cli: [new]])
        let stages = try requested.stages(replacing: previous, home: home)
        XCTAssertEqual(stages.count, 2)
        let overlap = try XCTUnwrap(stages.first)
        try overlap.apply(to: installed)
        XCTAssertEqual(Set(installed.appRules.compactMap(\.matchPath)), [old.executablePath, new.executablePath])
        let saved = try AirlockTargetBinding(reading: installed, home: home)
        XCTAssertEqual(saved, overlap)
        XCTAssertThrowsError(try requested.verify(installed, home: home))
        // Resuming after a shutdown / save failure must use the verified overlap.
        XCTAssertEqual(try requested.stages(replacing: saved, home: home), [requested])
        try requested.apply(to: installed)
        try requested.verify(installed, home: home)
        XCTAssertEqual(installed.appRules.compactMap(\.matchPath), [new.executablePath])
        XCTAssertTrue(try requested.stages(replacing: AirlockTargetBinding(reading: installed, home: home), home: home).isEmpty)
    }

    func testChangedSignerDirectorySlotOrDroppedApplicationKeepsExistingRules() throws {
        let old = identity("2.1.263")
        let installed = try manager([old])
        let original = try AirlockTargetBinding(reading: installed, home: home)
        let otherDir = DeusAppIdentity(signingIdentifier: old.signingIdentifier, designatedRequirement: old.designatedRequirement,
                                       executablePath: "/tmp/versions/2.1.284")
        let sameSignatureWrongSlot = AirlockTargetBinding(slots: ["/tmp/cli": [identity("2.1.284")]])
        let app = DeusAppIdentity(signingIdentifier: "org.example.desktop", designatedRequirement: "identifier \"org.example.desktop\"",
                                  executablePath: desktop + "/Contents/MacOS/Claude")
        let withDesktop = AirlockTargetBinding(slots: [cli: [old], desktop: [app]])
        try withDesktop.apply(to: installed)
        let savedDesktop = try AirlockTargetBinding(reading: installed, home: home)
        let cliOnly = AirlockTargetBinding(slots: [cli: [identity("2.1.284")]])
        XCTAssertThrowsError(try cliOnly.stages(replacing: savedDesktop, home: home))
        XCTAssertThrowsError(try sameSignatureWrongSlot.stages(replacing: original, home: home))
        for rejected in [identity("2.1.284", id: "org.example.foreign"),
                         identity("2.1.284", requirement: "identifier \"com.anthropic.claude-code\""),
                         identity("other-tool"), otherDir] {
            let proposed = AirlockTargetBinding(slots: [cli: [rejected]])
            XCTAssertThrowsError(try proposed.stages(replacing: original, home: home), rejected.executablePath)
        }
        XCTAssertEqual(Set(installed.appRules.compactMap(\.matchPath)), [old.executablePath, app.executablePath])
    }

    @MainActor
    func testFailedReadbackStopsBeforeAWriteCanRemoveThePreviousRule() async throws {
        let old = identity("2.1.263")
        let new = identity("2.1.284")
        let installed = try manager([old])
        let previous = try AirlockTargetBinding(reading: installed, home: home)
        let requested = AirlockTargetBinding(slots: [cli: [new]])
        var writes = [[String]]()
        let wrong = try manager([new])
        var readbacks = [wrong, installed]
        let store = AirlockTargetStore(save: { candidate in writes.append(candidate.appRules.compactMap(\.matchPath).sorted()) },
                                       reload: { readbacks.removeFirst() }, remove: { _ in XCTFail("Existing profile must survive") })
        do {
            try await requested.persist(replacing: previous, in: installed, home: home, forceSave: false, store: store) { _ in }
            XCTFail("A failed overlap readback must abort the update")
        } catch {
            XCTAssertEqual(writes, [[old.executablePath, new.executablePath].sorted(), [old.executablePath]])
            XCTAssertTrue(readbacks.isEmpty, "Verify restoration of the last known policy")
        }
    }

    @MainActor
    func testStaleSaveDoesNotRestoreOverAConcurrentPolicy() async throws {
        let old = identity("2.1.263")
        let installed = try manager([old])
        let previous = try AirlockTargetBinding(reading: installed, home: home)
        let requested = AirlockTargetBinding(slots: [cli: [identity("2.1.284")]])
        var writes = 0
        let stale = NSError(domain: NEVPNErrorDomain, code: NEVPNError.configurationStale.rawValue)
        let store = AirlockTargetStore(save: { _ in
            writes += 1
            throw stale
        }, reload: {
            XCTFail("A stale writer cannot read back its own update")
            return nil
        }, remove: { _ in XCTFail("The concurrent policy must survive") })
        do {
            try await requested.persist(replacing: previous, in: installed, home: home, forceSave: false, store: store) { _ in }
            XCTFail("A stale save must fail")
        } catch {
            XCTAssertEqual(error as NSError, stale)
            XCTAssertEqual(writes, 1)
        }
    }

    @MainActor
    func testUnverifiedNewProfileIsRemovedAndItsAbsenceReadBack() async throws {
        let new = identity("2.1.284")
        let installed = try manager([new])
        let requested = AirlockTargetBinding(slots: [cli: [new]])
        var removed = false
        var reads = 0
        let store = AirlockTargetStore(save: { _ in }, reload: {
            reads += 1
            return removed ? nil : try self.manager([new]) // The OS stripped the requested slot metadata.
        }, remove: { candidate in
            XCTAssertTrue(candidate === installed)
            removed = true
        })
        do {
            try await requested.persist(replacing: nil, in: installed, home: home, forceSave: false, store: store) { _ in }
            XCTFail("A new profile with failed readback must fail")
        } catch {
            XCTAssertTrue(removed)
            XCTAssertEqual(reads, 2)
        }
    }

    func testUnreadableOverlapCannotBeFinalized() throws {
        let old = identity("2.1.263")
        let new = identity("2.1.284")
        let installed = try manager([old])
        let overlap = AirlockTargetBinding(slots: [cli: [new, old]])
        try overlap.apply(to: installed)
        installed.appRules = try DeusPerAppPolicy(identities: [new]).makeAppRules()
        XCTAssertThrowsError(try AirlockTargetBinding(reading: installed, home: home))
        XCTAssertThrowsError(try overlap.verify(installed, home: home))
    }

    func testExplicitBindRepairsOnlyThePreviouslyStoppedOwnedPolicy() throws {
        let old = identity("2.1.263")
        let selected = AirlockTargetBinding(slots: [cli: [old]])
        let stopped = try manager([old])
        let proto = try XCTUnwrap(stopped.protocolConfiguration as? NETunnelProviderProtocol)
        proto.providerBundleIdentifier = AirlockProfile.providerID
        proto.providerConfiguration = ["wasOnDemandEnabled": true]
        stopped.protocolConfiguration = proto
        stopped.localizedDescription = AirlockProfile.legacyName
        stopped.isOnDemandEnabled = false
        XCTAssertEqual(try AirlockTargetBinding(reading: stopped, home: home).paths, [cli])
        XCTAssertFalse(stopped.isOnDemandEnabled, "Reading targets must not write or enable On Demand")
        XCTAssertThrowsError(try selected.verify(stopped, home: home, allowLegacy: true), "Starting still requires a repaired profile")
        try selected.apply(to: stopped)
        XCTAssertTrue(stopped.isOnDemandEnabled)
        XCTAssertNil((stopped.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["wasOnDemandEnabled"])
        try selected.verify(stopped, home: home)
        XCTAssertEqual(stopped.appRules.compactMap(\.matchPath), [old.executablePath])

        stopped.isOnDemandEnabled = false
        for flag: Any? in [nil, false, "true", NSNumber(value: 1)] {
            proto.providerConfiguration = flag.map { ["wasOnDemandEnabled": $0] }
            stopped.protocolConfiguration = proto
            XCTAssertThrowsError(try AirlockTargetBinding(reading: stopped, home: home))
        }
        proto.providerConfiguration = ["wasOnDemandEnabled": true]
        stopped.protocolConfiguration = proto
        let restricted = NEOnDemandRuleConnect()
        restricted.ssidMatch = ["Only here"]
        stopped.onDemandRules = [restricted]
        XCTAssertThrowsError(try AirlockTargetBinding(reading: stopped, home: home))
        stopped.onDemandRules = [NEOnDemandRuleConnect()]
        stopped.localizedDescription = "Other profile"
        XCTAssertThrowsError(try AirlockTargetBinding(reading: stopped, home: home))
    }

    func testOnlySelectedVendorCLIAllowsProvisioningAndAnyNewPinNeedsAStoppedExistingTransport() throws {
        let digest = String(repeating: "a", count: 64)
        let requested: [String: Any] = ["sha256": digest, "proxyPort": 1, "relayPort": 9876]
        let malformed: [String: Any] = ["sha256": digest, "proxyPort": true, "relayPort": 9876]
        let cliSelection = AirlockTargetBinding(slots: [cli: [identity("2.1.263")]])
        let desktopOnly = AirlockTargetBinding(slots: [desktop: [identity("2.1.263")]])
        XCTAssertThrowsError(try desktopOnly.validateProvisioning(requested, current: nil, status: nil, home: home))
        XCTAssertNoThrow(try cliSelection.validateProvisioning(requested, current: nil, status: nil, home: home))
        for status: NEVPNStatus in [.invalid, .connected, .connecting, .reasserting, .disconnecting] {
            XCTAssertThrowsError(try cliSelection.validateProvisioning(requested, current: nil, status: status, home: home))
            XCTAssertThrowsError(try cliSelection.validateProvisioning(requested, current: malformed, status: status, home: home))
            XCTAssertThrowsError(try cliSelection.validateProvisioning(requested, current: ["sha256": "old"], status: status, home: home))
            XCTAssertNoThrow(try cliSelection.validateProvisioning(requested, current: requested, status: status, home: home))
        }
        XCTAssertNoThrow(try cliSelection.validateProvisioning(requested, current: ["sha256": "old"], status: .disconnected, home: home))
    }

    func testLegacyDesktopBindingCanAdoptItsSelectedBundleWithoutLosingScope() throws {
        let app = DeusAppIdentity(signingIdentifier: "org.example.desktop", designatedRequirement: "identifier \"org.example.desktop\"",
                                  executablePath: desktop + "/Contents/MacOS/Claude")
        let installed = try manager([app])
        let legacy = try AirlockTargetBinding(reading: installed, home: home)
        let selected = AirlockTargetBinding(slots: [desktop: [app]])
        XCTAssertEqual(try selected.stages(replacing: legacy, home: home), [selected])
        try selected.apply(to: installed)
        let saved = try AirlockTargetBinding(reading: installed, home: home)
        XCTAssertEqual(saved.paths, [desktop])
        let alias = AirlockTargetBinding(slots: ["/tmp/Desktop-link": [app]])
        XCTAssertThrowsError(try alias.stages(replacing: saved, home: home))
    }

    func testInstalledVendorSignatureSurvivesRealSymlinkRotationWhenAvailable() throws {
        let vendor = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")
        let files = FileManager.default
        guard files.fileExists(atPath: vendor.path) else { throw XCTSkip("No installed vendor signature fixture") }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let versions = root.appendingPathComponent(".local/share/claude/versions")
        let link = root.appendingPathComponent(".local/bin/claude")
        try files.createDirectory(at: versions, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let first = versions.appendingPathComponent("2.1.263")
        let second = versions.appendingPathComponent("2.1.284")
        try files.copyItem(at: vendor.resolvingSymlinksInPath(), to: first)
        try files.linkItem(at: first, to: second)
        try files.createSymbolicLink(at: link, withDestinationURL: first)
        let initial = try AirlockTargetBinding.inspect([link.path], home: root)
        let installed = try manager(initial.policy.identities)
        try initial.apply(to: installed)
        try AirlockTargetBinding.verifyCurrent(installed, home: root)
        try files.removeItem(at: link)
        XCTAssertThrowsError(try AirlockTargetBinding.verifyCurrent(installed, home: root))
        try files.createSymbolicLink(at: link, withDestinationURL: second)
        try files.removeItem(at: first)
        XCTAssertThrowsError(try AirlockTargetBinding.verifyCurrent(installed, home: root))
        let updated = try AirlockTargetBinding.inspect([link.path], home: root)
        let stages = try updated.stages(replacing: AirlockTargetBinding(reading: installed, home: root), home: root)
        XCTAssertEqual(stages.count, 2)
        for stage in stages {
            try stage.apply(to: installed)
            try stage.verify(installed, home: root)
        }
        XCTAssertEqual(installed.appRules.map(\.matchPath), [second.path])
        try AirlockTargetBinding.verifyCurrent(installed, home: root)
    }

    func testRetargetedVendorLinkResolvesToActualNewBinaryAndRejectsForeignSignature() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let files = FileManager.default
        let versions = root.appendingPathComponent(".local/share/claude/versions")
        let link = root.appendingPathComponent(".local/bin/claude")
        try files.createDirectory(at: versions, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        var actual = [DeusAppIdentity]()
        for version in ["2.1.263", "2.1.284"] {
            let file = versions.appendingPathComponent(version)
            try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")).write(to: file)
            if files.fileExists(atPath: link.path) { try files.removeItem(at: link) }
            try files.createSymbolicLink(at: link, withDestinationURL: file)
            actual.append(try DeusAppIdentity.inspect(link))
            XCTAssertThrowsError(try AirlockTargetBinding.inspect([link.path], home: root),
                                 "A correctly signed non-vendor binary must not occupy the Claude CLI slot")
        }
        XCTAssertEqual(actual.map(\.signingIdentifier), [actual[0].signingIdentifier, actual[0].signingIdentifier])
        XCTAssertEqual(actual[0].designatedRequirement, actual[1].designatedRequirement)
        XCTAssertNotEqual(actual[0].executablePath, actual[1].executablePath)
    }
}
