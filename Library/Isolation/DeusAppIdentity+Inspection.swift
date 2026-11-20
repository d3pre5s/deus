#if os(macOS)
import Foundation
import Security

public extension DeusAppIdentity {
    /// Inspect selected signed code without executing it or trusting its basename.
    static func inspect(_ url: URL, requiring requirementText: String? = nil) throws -> DeusAppIdentity {
        guard url.isFileURL else { throw DeusIdentityError.invalidCode }
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        var code: SecStaticCode?
        try check(SecStaticCodeCreateWithPath(canonicalURL as CFURL, SecCSFlags(rawValue: 0), &code))
        guard let code else { throw DeusIdentityError.invalidCode }
        var requiredSignature: SecRequirement?
        if let requirementText {
            try check(SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(rawValue: 0), &requiredSignature))
            guard requiredSignature != nil else { throw DeusIdentityError.invalidCode }
        }
        try check(SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate),
                                            requiredSignature))

        var information: CFDictionary?
        try check(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information))
        guard let fields = information as? [String: Any],
              let identifier = fields[kSecCodeInfoIdentifier as String] as? String,
              let executable = fields[kSecCodeInfoMainExecutable as String] as? URL
        else { throw DeusIdentityError.invalidCode }

        var requirement: SecRequirement?
        try check(SecCodeCopyDesignatedRequirement(code, SecCSFlags(rawValue: 0), &requirement))
        guard let requirement else { throw DeusIdentityError.invalidCode }
        var requirementText: CFString?
        try check(SecRequirementCopyString(requirement, SecCSFlags(rawValue: 0), &requirementText))
        guard let requirementText else { throw DeusIdentityError.invalidCode }
        let identity = DeusAppIdentity(signingIdentifier: identifier,
                                       designatedRequirement: requirementText as String,
                                       executablePath: executable.resolvingSymlinksInPath().standardizedFileURL.path)
        _ = try DeusPerAppPolicy(identities: [identity]).makeAppRules()
        return identity
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw DeusIdentityError.security(status) }
    }
}

public enum DeusIdentityError: Error {
    case invalidCode
    case security(OSStatus)
}
#endif
