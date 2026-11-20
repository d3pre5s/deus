#if os(macOS)
import Foundation
import NetworkExtension

/// A logical selection keeps its original path while macOS rules refer to signed, resolved executables.
struct AirlockTargetBinding: Equatable {
    private static let metadataKey = "AirlockSelectedTargetsV1"
    private static let vendorIdentifier = "com.anthropic.claude-code"
    private static let vendorRequirement = """
    identifier "com.anthropic.claude-code" and anchor apple generic and \
    certificate 1[field.1.2.840.113635.100.6.2.6] exists and \
    certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = Q6L2SF6YDW
    """

    // The first executable is current. Other entries protect old versions during a verified replacement.
    private let slots: [String: [DeusAppIdentity]]
    private let legacy: Bool

    init(slots: [String: [DeusAppIdentity]]) {
        self.slots = slots
        legacy = false
    }

    var paths: [String] { slots.keys.sorted() }

    var policy: DeusPerAppPolicy {
        DeusPerAppPolicy(identities: paths.flatMap { slots[$0] ?? [] })
    }

    static func loginHome() throws -> URL {
        // A sandboxed host's HOME can point to its container.
        guard let directory = getpwuid(getuid())?.pointee.pw_dir else {
            throw AirlockProfile.error("Cannot determine the login home directory")
        }
        return URL(fileURLWithPath: String(cString: directory))
    }

    private static func safePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && !path.contains("\0") && URL(fileURLWithPath: path).standardizedFileURL.path == path
    }

    private static func vendorLink(in home: URL) -> String {
        home.appendingPathComponent(".local/bin/claude").path
    }

    private static func vendorVersion(_ identity: DeusAppIdentity, in home: URL) -> Bool {
        let url = URL(fileURLWithPath: identity.executablePath)
        let versions = home.appendingPathComponent(".local/share/claude/versions")
        return identity.signingIdentifier == vendorIdentifier && url.deletingLastPathComponent().path == versions.path &&
            url.lastPathComponent.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\z"#,
                                        options: .regularExpression) != nil
    }

    static func inspect(_ paths: [String], home: URL) throws -> Self {
        var slots = [String: [DeusAppIdentity]]()
        for path in paths {
            guard safePath(path), slots[path] == nil else {
                throw AirlockProfile.error("Expected distinct absolute paths for the selected signed applications")
            }
            let vendorCLI = path == vendorLink(in: home)
            let identity: DeusAppIdentity
            do {
                identity = try DeusAppIdentity.inspect(URL(fileURLWithPath: path), requiring: vendorCLI ? vendorRequirement : nil)
            } catch {
                throw AirlockProfile.error("Cannot verify the selected signed target at \(path): \(error.localizedDescription)")
            }
            if vendorCLI, !vendorVersion(identity, in: home) {
                throw AirlockProfile.error("The selected Claude CLI must point to a signed version in ~/.local/share/claude/versions")
            }
            slots[path] = [identity]
        }
        let selected = Self(slots: slots)
        _ = try selected.policy.makeAppRules()
        return selected
    }

    init(reading manager: NETunnelProviderManager, home: URL, allowStoppedLegacy: Bool = true) throws {
        try AirlockProfile.checkBinding(manager, allowStoppedLegacy: allowStoppedLegacy)
        var identities = [String: DeusAppIdentity]()
        for rule in manager.appRules {
            guard let path = rule.matchPath, identities[path] == nil else {
                throw AirlockProfile.error("Missing or duplicated executable in the saved rules")
            }
            identities[path] = DeusAppIdentity(signingIdentifier: rule.matchSigningIdentifier,
                                               designatedRequirement: rule.matchDesignatedRequirement, executablePath: path)
        }
        _ = try DeusPerAppPolicy(identities: Array(identities.values)).makeAppRules()
        let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
        var slots = [String: [DeusAppIdentity]]()
        if let raw = proto?.providerConfiguration?[Self.metadataKey] {
            guard let metadata = raw as? [String: [String]] else {
                throw AirlockProfile.error("Unreadable saved target selection")
            }
            for (slot, executables) in metadata {
                guard Self.safePath(slot), !executables.isEmpty else { throw AirlockProfile.error("Invalid saved target path") }
                slots[slot] = try executables.map { path in
                    guard let identity = identities.removeValue(forKey: path) else {
                        throw AirlockProfile.error("Saved target selection does not match the application rules")
                    }
                    return identity
                }
            }
            guard identities.isEmpty else { throw AirlockProfile.error("Saved target selection omits an application rule") }
            legacy = false
        } else {
            // Old releases saved only NEAppRules. Infer the stable vendor symlink from its exact signed version family.
            for identity in identities.values {
                let slot = Self.vendorVersion(identity, in: home) ? Self.vendorLink(in: home) : identity.executablePath
                guard slots[slot] == nil else { throw AirlockProfile.error("Ambiguous legacy application rules") }
                slots[slot] = [identity]
            }
            legacy = true
        }
        self.slots = slots
    }

    func apply(to manager: NETunnelProviderManager) throws {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            throw AirlockProfile.error("Missing tunnel protocol")
        }
        let rules = try policy.makeAppRules()
        var configuration = proto.providerConfiguration ?? [:]
        if AirlockProfile.wasStoppedByLegacyGUI(manager) {
            try AirlockProfile.checkBinding(manager, allowStoppedLegacy: true)
            configuration.removeValue(forKey: AirlockProfile.legacyStopKey)
            manager.isOnDemandEnabled = true
        }
        configuration[Self.metadataKey] = slots.mapValues { $0.map(\.executablePath) }
        proto.providerConfiguration = configuration
        manager.protocolConfiguration = proto
        manager.appRules = rules
    }

    static func verifyCurrent(_ manager: NETunnelProviderManager, home: URL) throws {
        do {
            let saved = try Self(reading: manager, home: home, allowStoppedLegacy: false)
            try inspect(saved.paths, home: home).verify(manager, home: home, allowLegacy: true)
        } catch {
            throw AirlockProfile.error("Cannot start with the saved application rules. Run airlock-cli-start to verify and bind the selected targets: \(error.localizedDescription)")
        }
    }

    func verify(_ manager: NETunnelProviderManager, home: URL, allowLegacy: Bool = false) throws {
        let saved = try Self(reading: manager, home: home, allowStoppedLegacy: false)
        if allowLegacy, saved.legacy {
            let previous = saved.policy.identities.sorted { $0.executablePath < $1.executablePath }
            let requested = policy.identities.sorted { $0.executablePath < $1.executablePath }
            if previous == requested { return }
        }
        guard saved == self else { throw AirlockProfile.error("Saved targets differ from requested paths or signatures") }
    }

    /// Return readback checkpoints. A new version is saved alongside the old rule before any rule is retired.
    func stages(replacing prior: Self?, home: URL) throws -> [Self] {
        guard let prior else { return [self] }
        if prior == self { return [] }
        var overlap = slots
        for (priorSlot, previous) in prior.slots {
            // A legacy rule only identifies the executable. Its initially selected bundle/symlink was not stored.
            var slot = priorSlot
            if slots[slot] == nil, prior.legacy, let match = slots.first(where: { $0.value == previous }) {
                slot = match.key
            }
            guard let selected = slots[slot]?.first else {
                throw AirlockProfile.error("Previously selected target is missing: \(priorSlot)")
            }
            for old in previous where old != selected {
                guard slot == Self.vendorLink(in: home), old.executablePath != selected.executablePath,
                      Self.vendorVersion(old, in: home), Self.vendorVersion(selected, in: home),
                      old.designatedRequirement == selected.designatedRequirement else {
                    throw AirlockProfile.error("Cannot replace a selected path or signing identity: \(slot)")
                }
                overlap[slot, default: []].append(old)
            }
        }
        let checkpoint = Self(slots: overlap)
        _ = try checkpoint.policy.makeAppRules() // Also rejects a retained path claimed by a different slot.
        if checkpoint == self || checkpoint == prior { return [self] }
        return [checkpoint, self]
    }

    func matchesPinnedCLI(_ descriptor: [String: Any], current: Any?, home: URL) throws -> Bool {
        guard let cli = slots[Self.vendorLink(in: home)]?.first, Self.vendorVersion(cli, in: home) else {
            throw AirlockProfile.error("Select the signed vendor CLI at ~/.local/bin/claude to use its transport")
        }
        // NSDictionary alone equates Boolean true with integer 1.
        guard let raw = current as? [String: Any], let pin = try? AirlockTransportPolicy.CLIBinding(descriptor: raw) else { return false }
        return NSDictionary(dictionary: pin.descriptor).isEqual(to: descriptor)
    }

    @discardableResult
    func validateProvisioning(_ descriptor: [String: Any], current: Any?, status: NEVPNStatus?, home: URL) throws -> Bool {
        if try matchesPinnedCLI(descriptor, current: current, home: home) { return false }
        if let status, status != .disconnected {
            throw AirlockProfile.error("Quit the selected applications and stop the Airlock VPN before provisioning a new CLI configuration")
        }
        return true
    }
}
#endif
