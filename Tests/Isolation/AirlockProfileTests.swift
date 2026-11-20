import NetworkExtension
import XCTest
@testable import DeusIsolation

final class AirlockProfileTests: XCTestCase {
    let provider = "io.github.d3pre5s.deusairlock.system"

    private func candidate() throws -> NETunnelProviderManager {
        let app = DeusAppIdentity(signingIdentifier: "fixture", designatedRequirement: "identifier \"fixture\"",
                                  executablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture")
        return try DeusPerAppPolicy(identities: [app]).makeCandidate(providerBundleIdentifier: provider)
    }

    func testStopOnlyStopsTheSelectedTransport() throws {
        let managed = try candidate()
        let rule = try XCTUnwrap(managed.appRules.first)
        let demand = try XCTUnwrap(managed.onDemandRules?.first)
        var stopped: [NEVPNConnection] = []
        XCTAssertTrue(AirlockProfile.stopTransport(managed, providerID: provider) { stopped.append($0) })
        XCTAssertEqual(stopped.count, 1)
        XCTAssertTrue(stopped.first === managed.connection)
        XCTAssertEqual(managed.appRules.first?.matchPath, rule.matchPath)
        XCTAssertTrue(managed.onDemandRules?.first === demand)
        try AirlockProfile.checkBinding(managed)
    }

    func testSelectionIsIndependentOfOrderAndDescription() throws {
        let managed = try candidate()
        managed.localizedDescription = "Renamed"
        let other = NETunnelProviderManager()
        other.localizedDescription = AirlockProfile.legacyName
        for managers in [[other, managed], [managed, other], [managed]] {
            XCTAssertTrue(try AirlockProfile.select(managers, providerID: provider) === managed)
        }
        XCTAssertNil(try AirlockProfile.select([other], providerID: provider))
        XCTAssertNil(try AirlockProfile.select([managed], providerID: "other"))
        XCTAssertThrowsError(try AirlockProfile.select([managed, candidate()], providerID: provider))
    }

    func testRouteAndSystemProxyOverridesCannotChangeProtectedPolicy() throws {
        let routing = ["includeAllNetworks", "systemProxyEnabled", "excludeDefaultRoute",
                       "autoRouteUseSubRangesByDefault", "excludeAPNsRoute"]
        let defaults = try AirlockProfile.protectedOptions([:])
        for key in routing {
            XCTAssertEqual(defaults[key], NSNumber(value: false))
            XCTAssertThrowsError(try AirlockProfile.protectedOptions([key: NSNumber(value: true)]))
            XCTAssertThrowsError(try AirlockProfile.protectedOptions([key: "true" as NSString]))
        }
    }

    func testLegacyProfileNeedsMatchingProviderTypeAndName() throws {
        let managed = try candidate()
        let proto = try XCTUnwrap(managed.protocolConfiguration as? NETunnelProviderProtocol)
        proto.providerConfiguration = nil
        managed.localizedDescription = AirlockProfile.legacyName
        XCTAssertTrue(try AirlockProfile.select([managed], providerID: provider) === managed)
        managed.localizedDescription = "Other per-app VPN"
        XCTAssertNil(try AirlockProfile.select([managed], providerID: provider))
        managed.localizedDescription = AirlockProfile.legacyName
        proto.providerConfiguration = [AirlockProfile.markerKey: "other"]
        XCTAssertNil(try AirlockProfile.select([managed], providerID: provider))
    }
}
