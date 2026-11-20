#if os(macOS)
    import Foundation
    import NetworkExtension

    /// Signed host entry point for managing the Airlock per-app policy.
    @MainActor public enum AirlockAcceptance {
        private static let name = "Deus Airlock — application isolation"

        private static func failure(_ text: String) -> NSError {
            NSError(domain: "AirlockAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        }

        private static func ownedManager() async throws -> NETunnelProviderManager? {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            return try AirlockProfile.select(managers, providerID: AppConfiguration.systemExtensionBundleID)
        }

        private static func policy(_ paths: [String]) throws -> AirlockTargetBinding {
            try AirlockTargetBinding.inspect(paths, home: AirlockTargetBinding.loginHome())
        }

        private static func check(_ manager: NETunnelProviderManager, _ selected: AirlockTargetBinding) throws {
            try selected.verify(manager, home: AirlockTargetBinding.loginHome(), allowLegacy: true)
        }

        /// Serialize new profile creation and pin changes across signed host processes.
        private static func lockUpdates() throws -> Int32 {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("deus-airlock-policy.lock").path
            let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw failure("Cannot open the Airlock policy lock") }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                throw failure("Another Airlock policy operation is in progress. Retry after it finishes.")
            }
            return fd
        }

        private static func bind(_ paths: [String], existing: NETunnelProviderManager?, descriptor: [String: Any]?) async throws {
            let home = try AirlockTargetBinding.loginHome()
            let selected = try AirlockTargetBinding.inspect(paths, home: home)
            let previous = try existing.map { try AirlockTargetBinding(reading: $0, home: home) }
            let manager = try existing ?? selected.policy.makeCandidate(providerBundleIdentifier: AppConfiguration.systemExtensionBundleID)
            if existing == nil { manager.localizedDescription = name }
            guard let template = manager.protocolConfiguration?.copy() as? NETunnelProviderProtocol else { throw failure("Missing tunnel protocol") }

            let original = template.providerConfiguration ?? [:]
            var settings = original
            settings[AirlockProfile.markerKey] = AirlockProfile.policyID
            var pinChanged = false
            if let descriptor {
                pinChanged = try selected.validateProvisioning(descriptor, current: original[AirlockProfile.cliBindingKey],
                                                              status: existing?.connection.status, home: home)
                settings[AirlockProfile.cliBindingKey] = descriptor
            } else {
                _ = try AirlockProfile.cliBinding(in: template)
            }
            template.providerConfiguration = settings
            TunnelSnapshot.identify(template)
            guard let snapshotID = template.providerConfiguration?[TunnelSnapshot.idKey] as? String, UUID(uuidString: snapshotID) != nil else {
                throw failure("Invalid saved snapshot identifier")
            }
            let forceSave = pinChanged || AirlockProfile.wasStoppedByLegacyGUI(manager) ||
                !NSDictionary(dictionary: original).isEqual(to: template.providerConfiguration ?? [:])
            let store = AirlockTargetStore(save: { try await $0.saveToPreferences() }, reload: ownedManager,
                                           remove: { try await $0.removeFromPreferences() })
            try await selected.persist(replacing: previous, in: manager, home: home, forceSave: forceSave, store: store) { candidate in
                guard try policy(paths) == selected else { throw failure("A selected application changed during binding. Retry.") }
                guard let proto = candidate.protocolConfiguration as? NETunnelProviderProtocol else { throw failure("Missing tunnel protocol") }
                var persisted = proto.providerConfiguration ?? [:]
                if let descriptor {
                    try selected.validateProvisioning(descriptor, current: persisted[AirlockProfile.cliBindingKey],
                                                       status: existing == nil ? nil : candidate.connection.status, home: home)
                    persisted[AirlockProfile.cliBindingKey] = descriptor
                }
                persisted[AirlockProfile.markerKey] = AirlockProfile.policyID
                persisted[TunnelSnapshot.idKey] = snapshotID
                proto.providerConfiguration = persisted
                candidate.protocolConfiguration = proto
            }
            guard try policy(paths) == selected else { throw failure("A selected application changed during binding. Retry.") }
            print("Read back \(selected.paths.count) exact app rules")
        }

        private static func cliBinding(_ values: [String]) throws -> AirlockTransportPolicy.CLIBinding {
            guard values.count >= 4, values[0].hasPrefix("/"),
                  let proxy = UInt16(values[1]), let relay = UInt16(values[2]), proxy != 0, relay != 0, proxy != relay
            else { throw failure("Supply CONFIG PROXY_PORT RELAY_PORT and the selected applications") }
            let config = try String(contentsOfFile: values[0], encoding: .utf8)
            return try AirlockTransportPolicy.CLIBinding(config: config, proxyPort: proxy, relayPort: relay)
        }

        #if AIRLOCK_ACCEPTANCE
        private static func folderFilter(_ action: String, _ values: [String]) async throws {
            let manager = NEFilterManager.shared()
            try await manager.loadFromPreferences()
            let label = "Deus Airlock — folder qualification"
            if let configuration = manager.providerConfiguration {
                guard manager.localizedDescription == label,
                      configuration.filterDataProviderBundleIdentifier == AppConfiguration.systemExtensionBundleID
                else { throw failure("Existing filter is outside this qualification") }
            }
            switch action {
            case "folder-filter-off" where values.isEmpty:
                if manager.providerConfiguration != nil { try await manager.removeFromPreferences() }
            case "folder-filter-on" where values.count == 1:
                guard let port = Int(values[0]), (49152...65535).contains(port)
                else { throw failure("Supply a high loopback TCP port") }
                // A sandboxed host's HOME can point to its container. Resolve the login home by UID.
                guard let record = getpwuid(getuid()), let directory = record.pointee.pw_dir
                else { throw failure("Cannot determine the login home directory") }
                let loginHome = URL(fileURLWithPath: String(cString: directory))
                let roots = [URL(fileURLWithPath: "/Applications/Claude.app"),
                             loginHome.appendingPathComponent(".local/share/claude/versions"),
                             loginHome.appendingPathComponent("Library/Application Support/Claude/claude-code")]
                    .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
                let configuration = NEFilterProviderConfiguration()
                configuration.filterSockets = true
                configuration.filterDataProviderBundleIdentifier = AppConfiguration.systemExtensionBundleID
                configuration.vendorConfiguration = ["port": port, "roots": roots]
                manager.localizedDescription = label
                manager.providerConfiguration = configuration
                manager.isEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
                guard manager.isEnabled,
                      manager.providerConfiguration?.vendorConfiguration?["port"] as? Int == port,
                      manager.providerConfiguration?.vendorConfiguration?["roots"] as? [String] == roots
                else { throw failure("Filter configuration readback failed") }
            default: throw failure("Expected folder-filter-on PORT or folder-filter-off")
            }
        }

        #endif

        public static func run(_ arguments: [String], qualification: Bool = false) async throws {
            guard AppConfiguration.isAirlock, let action = arguments.first else { throw failure("Missing acceptance action") }
            let values = Array(arguments.dropFirst())
            let controls = ["status", "targets", "bind", "provision-cli", "verify-cli", "start"]
            #if AIRLOCK_ACCEPTANCE
            guard qualification || controls.contains(action) else { throw failure("Unknown Airlock control action") }
            if qualification, action == "activate", values.isEmpty {
                let result = try await SystemExtension.install()
                print("Extension activation result: \(String(describing: result))")
                return
            }
            if qualification, action.hasPrefix("folder-filter-") {
                try await folderFilter(action, values)
                return
            }
            #else
            guard controls.contains(action) else { throw failure("Unknown Airlock control action") }
            #endif
            let modifying = ["bind", "provision-cli", "start", "remove"].contains(action)
            let lock = modifying ? try lockUpdates() : nil
            defer { if let lock { close(lock) } }
            let existing = try await ownedManager()
            switch action {
            case "status" where values.isEmpty:
                print("Acceptance policy present: \(existing != nil); connection status: \(existing?.connection.status.rawValue ?? 0)")
            case "targets" where values.isEmpty:
                let home = try AirlockTargetBinding.loginHome()
                let paths = try existing.map { try AirlockTargetBinding(reading: $0, home: home).paths } ?? []
                guard let output = String(data: try JSONEncoder().encode(paths), encoding: .utf8) else {
                    throw failure("Cannot encode saved target paths")
                }
                print(output)
            case "verify-cli":
                guard let existing, let proto = existing.protocolConfiguration as? NETunnelProviderProtocol else {
                    throw failure("Provision the Airlock CLI before starting it")
                }
                let binding = try cliBinding(values)
                let home = try AirlockTargetBinding.loginHome()
                let selected = try AirlockTargetBinding.inspect(Array(values.dropFirst(3)), home: home)
                try selected.verify(existing, home: home)
                guard try selected.matchesPinnedCLI(binding.descriptor, current: proto.providerConfiguration?[AirlockProfile.cliBindingKey], home: home) else {
                    throw failure("Current CLI configuration differs from the saved transport. Verify your settings and run airlock-cli-start --provision.")
                }
            case "bind", "provision-cli":
                if action == "provision-cli" {
                    let binding = try cliBinding(values)
                    try await bind(Array(values.dropFirst(3)), existing: existing, descriptor: binding.descriptor)
                } else {
                    try await bind(values, existing: existing, descriptor: nil)
                }
            case "start" where values.count >= 2 && values[0].hasPrefix("/"):
                guard let existing else { throw failure("Bind and read back the policy first") }
                try check(existing, policy(Array(values.dropFirst())))
                let config = try String(contentsOfFile: values[0], encoding: .utf8)
                guard let proto = existing.protocolConfiguration as? NETunnelProviderProtocol else {
                    throw failure("Missing per-app tunnel protocol")
                }
                try AirlockTransportPolicy.validate(config, binding: AirlockProfile.cliBinding(in: proto))
                try existing.connection.startVPNTunnel(options: ["manualStart": NSNumber(value: true), "configContent": config as NSString])
                print("Submitted tunnel start request")
            #if AIRLOCK_ACCEPTANCE
            case "remove" where qualification && values.isEmpty:
                if let existing { try await existing.removeFromPreferences() }
                guard try await ownedManager() == nil else { throw failure("Acceptance policy still present") }
                print("Acceptance policy absent")
            #endif
            default:
                throw failure("Expected activate, status, bind PATH..., start CONFIG PATH..., or remove")
            }
        }
    }
#endif
