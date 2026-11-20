import Darwin
import Foundation
import NetworkExtension

/// A snapshot belongs to one saved VPN configuration. The old shared plist has no owner information.
struct TunnelSnapshot {
    static let idKey = "TunnelStartOptionsID"
    private let url: URL

    static func identify(_ proto: NETunnelProviderProtocol) {
        var settings = proto.providerConfiguration ?? [:]
        if settings[idKey] == nil {
            settings[idKey] = UUID().uuidString
            proto.providerConfiguration = settings
        }
    }

    init(directory: URL, configuration: NETunnelProviderProtocol, protected: Bool) throws {
        guard let raw = configuration.providerConfiguration?[Self.idKey] as? String,
              let id = UUID(uuidString: raw) else {
            throw NSError(domain: "TunnelSnapshot", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This VPN profile needs a snapshot ID. Bind Airlock or start the profile from its app.",
            ])
        }
        let scope = protected ? "per-app" : "profile"
        url = directory.appendingPathComponent("TunnelOptions", isDirectory: true)
            .appendingPathComponent("\(scope)-\(id.uuidString).plist")
    }

    func load() throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func activate(_ candidate: Data, apply: () throws -> Void, restore: () throws -> Void) throws {
        do {
            try apply()
            try commit(candidate)
        } catch {
            let original = error
            do {
                try restore()
            } catch {
                throw NSError(domain: "TunnelSnapshot", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Tunnel activation and recovery both failed: \(original.localizedDescription) / \(error.localizedDescription)",
                ])
            }
            throw original
        }
    }

    private func commit(_ candidate: Data) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staged = directory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: staged) }
        try candidate.write(to: staged, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        guard rename(staged.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
