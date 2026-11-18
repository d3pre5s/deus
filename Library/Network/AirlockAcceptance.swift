#if os(macOS) && AIRLOCK_ACCEPTANCE
    import Foundation
    import NetworkExtension

    /// Explicit local qualification commands in the signed test host.
    @MainActor public enum AirlockAcceptance {
        private static let name = "Deus Airlock — local acceptance"

        private static func failure(_ text: String) -> NSError {
            NSError(domain: "AirlockAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        }

        private static func ownedManager() async throws -> NETunnelProviderManager? {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let owned = managers.filter {
                $0.localizedDescription == name &&
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppConfiguration.systemExtensionBundleID
            }
            guard owned.count <= 1 else { throw failure("Multiple acceptance configurations found") }
            return owned.first
        }

        private static func policy(_ paths: [String]) throws -> DeusPerAppPolicy {
            guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else {
                throw failure("Supply the absolute paths of the selected signed applications")
            }
            return DeusPerAppPolicy(identities: try paths.map { try DeusAppIdentity.inspect(URL(fileURLWithPath: $0)) })
        }

        private static func check(_ manager: NETunnelProviderManager, _ selected: DeusPerAppPolicy) throws {
            let rules = manager.appRules ?? []
            guard manager.isEnabled, DeusPerAppPolicy.hasUnconditionalConnect(manager),
                  (manager.excludedDomains ?? []).isEmpty,
                  manager.protocolConfiguration?.includeAllNetworks == false,
                  rules.count == selected.identities.count,
                  selected.identities.allSatisfy({ identity in rules.contains { matches($0, identity) } })
            else { throw failure("Persisted policy differs from requested paths, signatures or on-demand rules") }
        }

        private static func matches(_ rule: NEAppRule, _ id: DeusAppIdentity) -> Bool {
            rule.matchPath == id.executablePath && rule.matchSigningIdentifier == id.signingIdentifier &&
                rule.matchDesignatedRequirement == id.designatedRequirement &&
                rule.matchTools == nil && (rule.matchDomains ?? []).isEmpty
        }

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

        public static func run(_ arguments: [String]) async throws {
            guard AppConfiguration.isAirlock, let action = arguments.first else { throw failure("Missing acceptance action") }
            let values = Array(arguments.dropFirst())
            if action == "activate", values.isEmpty {
                let result = try await SystemExtension.install()
                print("Extension activation result: \(String(describing: result))")
                return
            }
            if action.hasPrefix("folder-filter-") {
                try await folderFilter(action, values)
                return
            }
            let existing = try await ownedManager()
            switch action {
            case "status" where values.isEmpty:
                print("Acceptance policy present: \(existing != nil); connection status: \(existing?.connection.status.rawValue ?? 0)")
            case "bind":
                let selected = try policy(values)
                let requested = try selected.makeAppRules()
                if let existing {
                    let current = existing.appRules ?? []
                    let retained = selected.identities.filter { id in current.contains { matches($0, id) } }
                    // Validate the old policy before extending it. Never narrow its scope on rebind.
                    try check(existing, DeusPerAppPolicy(identities: retained))
                    if current.count < requested.count {
                        existing.appRules = requested
                        try await existing.saveToPreferences()
                    }
                } else {
                    let candidate = try selected.makeCandidate(providerBundleIdentifier: AppConfiguration.systemExtensionBundleID)
                    candidate.localizedDescription = name
                    try await candidate.saveToPreferences()
                }
                guard let saved = try await ownedManager() else { throw failure("Policy missing after save") }
                try check(saved, selected)
                print("Read back \(selected.identities.count) exact app rules")
            case "start" where values.count >= 2 && values[0].hasPrefix("/"):
                guard let existing else { throw failure("Bind and read back the policy first") }
                try check(existing, policy(Array(values.dropFirst())))
                let config = try String(contentsOfFile: values[0], encoding: .utf8)
                try existing.connection.startVPNTunnel(options: ["manualStart": NSNumber(value: true), "configContent": config as NSString])
                print("Submitted tunnel start request")
            case "remove" where values.isEmpty:
                if let existing { try await existing.removeFromPreferences() }
                guard try await ownedManager() == nil else { throw failure("Acceptance policy still present") }
                print("Acceptance policy absent")
            default:
                throw failure("Expected activate, status, bind PATH..., start CONFIG PATH..., or remove")
            }
        }
    }
#endif
