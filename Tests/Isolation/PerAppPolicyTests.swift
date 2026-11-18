import Foundation
import NetworkExtension
import XCTest
@testable import DeusIsolation

final class PerAppPolicyTests: XCTestCase {
    private let identity = DeusAppIdentity(
        signingIdentifier: "com.example.Claude",
        designatedRequirement: "identifier \"com.example.Claude\" and anchor apple generic",
        executablePath: "/Applications/Claude.app/Contents/MacOS/Claude"
    )

    func testParentRuleIncludesInheritedToolsWithoutGlobalHelperRules() throws {
        let rules = try DeusPerAppPolicy(identities: [identity]).makeAppRules()
        XCTAssertEqual(rules.count, 1)
        let parent = try XCTUnwrap(rules.first)
        XCTAssertEqual(parent.matchSigningIdentifier, "com.example.Claude")
        XCTAssertEqual(parent.matchDesignatedRequirement, identity.designatedRequirement)
        XCTAssertEqual(parent.matchPath, "/Applications/Claude.app/Contents/MacOS/Claude")
        XCTAssertNil(parent.matchTools, "An empty helper list would restrict scope instead of inheriting all helpers")
        XCTAssertNil(parent.matchDomains, "Selected applications must not get a destination-domain bypass")
    }

    func testEmptySelectionCannotProduceAnUnscopedPolicy() {
        XCTAssertThrowsError(try DeusPerAppPolicy(identities: []).makeAppRules())
    }

    func testConflictingIdentityForSameExecutableIsRejected() {
        let changed = DeusAppIdentity(signingIdentifier: "com.example.Other",
                                      designatedRequirement: "identifier \"com.example.Other\"",
                                      executablePath: identity.executablePath)
        XCTAssertThrowsError(try DeusPerAppPolicy(identities: [identity, changed]).makeAppRules())
    }

    func testRelativeOrTraversalPathsAreRejected() {
        for path in ["Claude", "/Applications/../tmp/Claude", "", "/"] {
            let invalid = DeusAppIdentity(signingIdentifier: identity.signingIdentifier,
                                          designatedRequirement: identity.designatedRequirement,
                                          executablePath: path)
            XCTAssertThrowsError(try DeusPerAppPolicy(identities: [invalid]).makeAppRules(), path)
        }
    }

    func testInvalidSigningRequirementIsRejectedBeforeSystemPreferences() {
        let invalid = DeusAppIdentity(signingIdentifier: identity.signingIdentifier,
                                      designatedRequirement: "not a code requirement",
                                      executablePath: identity.executablePath)
        XCTAssertThrowsError(try DeusPerAppPolicy(identities: [invalid]).makeAppRules())
    }

    func testSiblingExecutableRemainsAnIndependentExactRule() throws {
        let sibling = DeusAppIdentity(signingIdentifier: "com.example.ClaudeOther",
                                      designatedRequirement: "identifier \"com.example.ClaudeOther\"",
                                      executablePath: "/Applications/ClaudeOther.app/Contents/MacOS/Claude")
        let rules = try DeusPerAppPolicy(identities: [identity, sibling]).makeAppRules()
        XCTAssertEqual(rules.map(\.matchPath), [identity.executablePath, sibling.executablePath])
    }

    func testCandidateUsesPerAppRoutingAndHasNoDomainOrProbeBypass() throws {
        let candidate = try DeusPerAppPolicy(identities: [identity])
            .makeCandidate(providerBundleIdentifier: "io.github.d3pre5s.deusairlock.system")
        XCTAssertEqual(candidate.routingMethod, .sourceApplication)
        XCTAssertEqual(candidate.appRules.count, 1)
        XCTAssertTrue(candidate.isEnabled)
        XCTAssertTrue(candidate.isOnDemandEnabled)
        let connection = try XCTUnwrap(candidate.onDemandRules?.first as? NEOnDemandRuleConnect)
        XCTAssertEqual(candidate.onDemandRules?.count, 1)
        XCTAssertNil(connection.probeURL)
        XCTAssertTrue(candidate.excludedDomains.isEmpty)
        let configuration = try XCTUnwrap(candidate.protocolConfiguration as? NETunnelProviderProtocol)
        XCTAssertEqual(configuration.providerBundleIdentifier, "io.github.d3pre5s.deusairlock.system")
        XCTAssertFalse(configuration.includeAllNetworks)
    }

    func testCandidateRejectsEmptyProviderBeforePreferences() {
        XCTAssertThrowsError(try DeusPerAppPolicy(identities: [identity]).makeCandidate(providerBundleIdentifier: ""))
    }
}
