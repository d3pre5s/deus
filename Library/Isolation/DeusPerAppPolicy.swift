#if os(macOS)
import Foundation
import NetworkExtension
import Security

/// A selected executable identity, never a recursive directory rule.
public struct DeusAppIdentity: Equatable, Sendable {
    public let signingIdentifier: String
    public let designatedRequirement: String
    public let executablePath: String
}

/// Offline preparation only. No preferences are saved and no tunnel is started.
public struct DeusPerAppPolicy {
    public let identities: [DeusAppIdentity]

    public init(identities: [DeusAppIdentity]) {
        self.identities = identities
    }

    /// Creates an in-memory candidate only; saving/activation needs a separate
    /// qualified installation flow. This does not prove OS enforcement.
    public func makeCandidate(providerBundleIdentifier: String) throws -> NETunnelProviderManager {
        guard !providerBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeusPolicyError.missingProvider
        }
        let rules = try makeAppRules()
        let manager = NETunnelProviderManager.forPerAppVPN()
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = providerBundleIdentifier
        configuration.serverAddress = "Deus Airlock"
        // Scope comes from per-app rules. Do not take over other applications.
        configuration.includeAllNetworks = false
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "Deus Airlock — application isolation"
        manager.appRules = rules
        manager.excludedDomains = []
        let connect = NEOnDemandRuleConnect()
        connect.interfaceTypeMatch = .any
        manager.onDemandRules = [connect]
        manager.isOnDemandEnabled = true
        manager.isEnabled = true
        return manager
    }

    /// Verify the effective on-demand scope after macOS reloads the profile.
    public static func hasUnconditionalConnect(_ manager: NETunnelProviderManager) -> Bool {
        guard manager.routingMethod == .sourceApplication, manager.isOnDemandEnabled,
              let rules = manager.onDemandRules, rules.count == 1,
              let rule = rules.first as? NEOnDemandRuleConnect else { return false }
        return rule.interfaceTypeMatch == .any && rule.probeURL == nil &&
            rule.ssidMatch == nil && rule.dnsSearchDomainMatch == nil && rule.dnsServerAddressMatch == nil
    }

    public func makeAppRules() throws -> [NEAppRule] {
        guard !identities.isEmpty else { throw DeusPolicyError.emptySelection }
        var paths = Set<String>()
        return try identities.map { identity in
            let path = identity.executablePath
            guard path.hasPrefix("/"), path != "/", !path.contains("\0"),
                  URL(fileURLWithPath: path).standardizedFileURL.path == path
            else { throw DeusPolicyError.invalidExecutablePath }
            guard paths.insert(path).inserted else { throw DeusPolicyError.duplicateExecutable }
            guard !identity.signingIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw DeusPolicyError.missingSigningIdentifier }
            var requirement: SecRequirement?
            let result = SecRequirementCreateWithString(identity.designatedRequirement as CFString,
                                                       SecCSFlags(rawValue: 0), &requirement)
            guard result == errSecSuccess, requirement != nil else {
                throw DeusPolicyError.invalidSigningRequirement
            }
            let rule = NEAppRule(signingIdentifier: identity.signingIdentifier,
                                 designatedRequirement: identity.designatedRequirement)
            rule.matchPath = path
            // nil includes the parent AND inherited tools. A helper whitelist
            // changes that meaning and must not be used for our product scope.
            rule.matchTools = nil
            return rule
        }
    }
}

public enum DeusPolicyError: Error {
    case emptySelection
    case invalidExecutablePath
    case duplicateExecutable
    case missingSigningIdentifier
    case invalidSigningRequirement
    case missingProvider
}
#endif
