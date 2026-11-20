#if os(macOS)
import Foundation
import NetworkExtension

enum AirlockProfile {
    static let providerID = "io.github.d3pre5s.deusairlock.system"
    static let cliBindingKey = "AirlockCLITransport"
    static let markerKey = "AirlockManagedPolicy"
    static let policyID = "deus-airlock.per-app.v1"
    static let legacyName = "Deus Airlock — local acceptance"

    static func owns(_ manager: NEVPNManager, providerID: String) -> Bool {
        guard let tunnel = manager as? NETunnelProviderManager, tunnel.routingMethod == .sourceApplication,
              let proto = tunnel.protocolConfiguration as? NETunnelProviderProtocol,
              proto.providerBundleIdentifier == providerID else { return false }
        if let marker = proto.providerConfiguration?[markerKey] {
            return marker as? String == policyID
        }
        return tunnel.localizedDescription == legacyName
    }

    static func select(_ managers: [NETunnelProviderManager], providerID: String) throws -> NETunnelProviderManager? {
        let matches = managers.filter { owns($0, providerID: providerID) }
        guard matches.count <= 1 else { throw error("Multiple managed Airlock policies found") }
        return matches.first
    }

    static func stopTransport(_ manager: NEVPNManager, providerID: String,
                              stop: (NEVPNConnection) -> Void = { $0.stopVPNTunnel() }) -> Bool {
        guard owns(manager, providerID: providerID) else { return false }
        stop(manager.connection)
        return true
    }

    static func hasExactRules(_ rules: [NEAppRule]) -> Bool {
        !rules.isEmpty && rules.allSatisfy { rule in
            guard let path = rule.matchPath, path.hasPrefix("/"), path != "/",
                  !rule.matchSigningIdentifier.isEmpty, !rule.matchDesignatedRequirement.isEmpty else { return false }
            return rule.matchTools == nil && (rule.matchDomains ?? []).isEmpty
        }
    }

    static let legacyStopKey = "wasOnDemandEnabled"

    static func wasStoppedByLegacyGUI(_ manager: NETunnelProviderManager) -> Bool {
        guard !manager.isOnDemandEnabled, owns(manager, providerID: providerID),
              let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
              let flag = proto.providerConfiguration?[legacyStopKey] as? NSNumber else { return false }
        return CFGetTypeID(flag) == CFBooleanGetTypeID() && flag.boolValue
    }

    static func checkBinding(_ manager: NETunnelProviderManager, allowStoppedLegacy: Bool = false) throws {
        guard manager.isEnabled, hasExactRules(manager.appRules), manager.excludedDomains.isEmpty,
              manager.protocolConfiguration?.includeAllNetworks == false,
              DeusPerAppPolicy.hasUnconditionalConnect(manager, allowDisabled: allowStoppedLegacy && wasStoppedByLegacyGUI(manager)) else {
            throw error("Airlock requires verified application rules and unconditional On Demand. Run airlock-cli-start to bind them.")
        }
    }

    static func protectedOptions(_ options: [String: NSObject]) throws -> [String: NSObject] {
        var safe = options.filter { $0.key == "configContent" || $0.key == "manualStart" }
        for key in ["includeAllNetworks", "systemProxyEnabled", "excludeDefaultRoute", "autoRouteUseSubRangesByDefault", "excludeAPNsRoute"] {
            if let value = options[key] {
                guard let number = value as? NSNumber, !number.boolValue else {
                    throw error("Airlock disallows the tunnel override " + key)
                }
            }
            safe[key] = NSNumber(value: false)
        }
        return safe
    }

    static func cliBinding(in proto: NETunnelProviderProtocol) throws -> AirlockTransportPolicy.CLIBinding? {
        guard let raw = proto.providerConfiguration?[cliBindingKey] else { return nil }
        guard let descriptor = raw as? [String: Any] else { throw error("Invalid saved CLI transport binding") }
        return try AirlockTransportPolicy.CLIBinding(descriptor: descriptor)
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "AirlockProfile", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
