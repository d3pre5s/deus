import Darwin
import DeusIsolation
import Foundation

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else {
    FileHandle.standardError.write(Data("Usage: deus-airlock-policy /absolute/App.app [/absolute/executable ...]\nInspects signed code and prepares rule metadata only. Does not install a VPN.\n".utf8))
    exit(EX_USAGE)
}

do {
    let identities = try paths.map { try DeusAppIdentity.inspect(URL(fileURLWithPath: $0)) }
    _ = try DeusPerAppPolicy(identities: identities).makeAppRules()
    let preview: [String: Any] = [
        "schema_version": 1,
        "policy_installed": false,
        "network_isolation_verified": false,
        "requested_scope": "selected-app-and-inherited-helpers",
        "recursive_directory_enforcement": false,
        "applications": identities.map { identity in
            ["signing_identifier": identity.signingIdentifier,
             "designated_requirement": identity.designatedRequirement,
             "executable_path": identity.executablePath]
        },
    ]
    let data = try JSONSerialization.data(withJSONObject: preview, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Cannot prepare policy: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
