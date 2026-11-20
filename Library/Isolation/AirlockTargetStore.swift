#if os(macOS)
import Foundation
import NetworkExtension

/// All three operations act on the same preferences domain. The host holds the policy lock throughout.
@MainActor
struct AirlockTargetStore {
    let save: (NETunnelProviderManager) async throws -> Void
    let reload: () async throws -> NETunnelProviderManager?
    let remove: (NETunnelProviderManager) async throws -> Void
}

private struct TargetCheckpoint {
    let binding: AirlockTargetBinding
    let proto: NETunnelProviderProtocol
    let rules: [NEAppRule]
    let onDemand: Bool

    init(_ binding: AirlockTargetBinding, manager: NETunnelProviderManager) throws {
        guard let proto = manager.protocolConfiguration?.copy() as? NETunnelProviderProtocol else {
            throw AirlockProfile.error("Missing tunnel protocol")
        }
        self.binding = binding
        self.proto = proto
        rules = manager.appRules
        onDemand = manager.isOnDemandEnabled
    }

    func verify(_ manager: NETunnelProviderManager?, home: URL) throws -> NETunnelProviderManager {
        guard let manager, let actual = manager.protocolConfiguration as? NETunnelProviderProtocol,
              actual.providerBundleIdentifier == proto.providerBundleIdentifier,
              NSDictionary(dictionary: actual.providerConfiguration ?? [:]).isEqual(to: proto.providerConfiguration ?? [:]),
              manager.isOnDemandEnabled == onDemand,
              try AirlockTargetBinding(reading: manager, home: home, allowStoppedLegacy: !onDemand) == binding else {
            throw AirlockProfile.error("Saved Airlock rules or provider settings failed readback")
        }
        if let expectedPin = proto.providerConfiguration?[AirlockProfile.cliBindingKey] as? [String: Any],
           (try? AirlockTransportPolicy.CLIBinding(descriptor: expectedPin)) != nil {
            _ = try AirlockProfile.cliBinding(in: actual)
        }
        return manager
    }

    func restore(to manager: NETunnelProviderManager) {
        manager.appRules = rules
        manager.protocolConfiguration = proto
        manager.isOnDemandEnabled = onDemand
    }
}

extension AirlockTargetBinding {
    @MainActor
    func persist(replacing prior: Self?, in manager: NETunnelProviderManager, home: URL, forceSave: Bool,
                 store: AirlockTargetStore, configure: (NETunnelProviderManager) throws -> Void) async throws {
        var stages = try stages(replacing: prior, home: home)
        if stages.isEmpty, forceSave { stages = [self] }
        var saved = manager
        var verified = prior
        for stage in stages {
            let previous = try verified.map { try TargetCheckpoint($0, manager: saved) }
            try configure(saved)
            try stage.apply(to: saved)
            let expected = try TargetCheckpoint(stage, manager: saved)
            // A stale save must fail without overwriting a newer preferences revision.
            try await store.save(saved)
            do {
                saved = try expected.verify(await store.reload(), home: home)
                verified = stage
            } catch let readbackError {
                do {
                    // Use the manager that performed the write, never a freshly loaded concurrent writer's revision.
                    if let previous {
                        previous.restore(to: saved)
                        try await store.save(saved)
                        _ = try previous.verify(await store.reload(), home: home)
                    } else {
                        try await store.remove(saved)
                        guard try await store.reload() == nil else { throw AirlockProfile.error("New profile still present") }
                    }
                } catch {
                    throw AirlockProfile.error("Policy readback failed and recovery could not be verified: \(error.localizedDescription)")
                }
                throw readbackError
            }
        }
        try verify(saved, home: home)
    }
}
#endif
