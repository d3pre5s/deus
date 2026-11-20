#if os(macOS)
import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Security

/// The closed sing-box schema used by the macOS per-app tunnel.
public enum AirlockTransportPolicy {
    public struct CLIBinding {
        public let proxyPort: UInt16
        public let relayPort: UInt16
        private let sha256: String

        /// Provisioning supplies the two ports independently from client.json and peer.json.
        public init(config: String, proxyPort: UInt16, relayPort: UInt16) throws {
            guard proxyPort > 0, relayPort > 0, proxyPort != relayPort else { throw Rejection.binding }
            guard config.utf8.count <= maximumConfigSize else { throw Rejection.json }
            self.proxyPort = proxyPort
            self.relayPort = relayPort
            sha256 = digest(config)
            try validate(config, binding: self)
        }

        /// Read only from the saved, owned per-app manager's provider configuration.
        public init(descriptor: [String: Any]) throws {
            guard Set(descriptor.keys) == ["sha256", "proxyPort", "relayPort"],
                  let hash = descriptor["sha256"] as? String, hash.utf8.count == 64,
                  hash.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }),
                  let proxyPort = port(descriptor["proxyPort"]), let relayPort = port(descriptor["relayPort"]),
                  proxyPort != relayPort else { throw Rejection.binding }
            sha256 = hash
            self.proxyPort = proxyPort
            self.relayPort = relayPort
        }

        public var descriptor: [String: Any] {
            ["sha256": sha256, "proxyPort": Int(proxyPort), "relayPort": Int(relayPort)]
        }

        fileprivate func matches(_ config: String) -> Bool { sha256 == digest(config) }
    }

    public static func validate(_ config: String, binding: CLIBinding? = nil) throws {
        _ = try validatedOutbound(config, binding: binding)
    }

    /// Changing a running tunnel's peer or its authentication requires an explicit new selection.
    public static func checkReload(_ config: String, replacing previous: String, binding: CLIBinding? = nil) throws {
        let proposed = try validatedOutbound(config, binding: binding)
        if config.utf8.elementsEqual(previous.utf8) { return }
        let current = try validatedOutbound(previous, binding: binding)
        guard NSDictionary(dictionary: current).isEqual(to: proposed) else { throw Rejection.changedPeer }
    }

    private static let maximumConfigSize = 128 * 1024

    private static func validatedOutbound(_ config: String, binding: CLIBinding?) throws -> Object {
        guard config.utf8.count <= maximumConfigSize else { throw Rejection.json }
        let data = Data(config.utf8)
        if let binding, !binding.matches(config) { throw Rejection.binding }
        let memberCount = try checkJSONTokens(data)
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let root = object(raw, keys: ["log", "inbounds", "outbounds", "dns", "route"]),
              countMembers(root) == memberCount else { throw Rejection.json }
        if let value = root["log"] {
            guard let log = object(value, keys: ["level"]),
                  ["warn", "warning", "error", "fatal", "info"].contains(log["level"] as? String ?? "")
            else { throw Rejection.log }
        }
        guard let outbounds = root["outbounds"] as? [Object], outbounds.count == 1 else { throw Rejection.peer }
        let outbound = try validatePeer(outbounds[0], binding)
        guard let inbounds = root["inbounds"] as? [Object], inbounds.count == (binding == nil ? 1 : 2),
              let tun = inbounds.first(where: { $0["type"] as? String == "tun" })
        else { throw Rejection.tun }
        let tunTag = try validateTun(tun)
        var inboundTags: Set<String> = [tunTag]
        if let binding {
            guard let http = inbounds.first(where: { $0["type"] as? String == "http" }) else { throw Rejection.listener }
            let httpTag = try validateCLI(http, binding)
            guard inboundTags.insert(httpTag).inserted else { throw Rejection.listener }
        }
        try validateDNS(root["dns"], outbound)
        try validateRoute(root["route"], outbound, inboundTags)
        return outbounds[0]
    }

    private typealias Object = [String: Any]

    private enum Rejection: String, LocalizedError {
        case json = "Invalid or ambiguous protected profile JSON"
        case log = "Unsupported protected logging configuration"
        case binding = "Invalid CLI binding or protected profile fingerprint"
        case tun = "Protected mode requires one dual-stack TUN with full routes"
        case listener = "Invalid provisioned CLI TLS listener"
        case peer = "Protected mode requires one numeric VLESS/REALITY peer or the provisioned relay"
        case changedPeer = "Reload cannot change the selected VLESS/REALITY outbound"
        case dns = "Protected DNS must use one resolver through the selected outbound"
        case route = "Protected routing must handle DNS and use only the selected outbound"

        var errorDescription: String? { rawValue }
    }

    private static func digest(_ config: String) -> String {
        SHA256.hash(data: Data(config.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func object(_ value: Any?, keys: Set<String>) -> Object? {
        guard let result = value as? Object, Set(result.keys).isSubset(of: keys) else { return nil }
        return result
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return Int(number.stringValue)
    }

    private static func port(_ value: Any?) -> UInt16? {
        guard let n = integer(value), n > 0 else { return nil }
        return UInt16(exactly: n)
    }

    private static func enabled(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (65 ... 90).contains(byte) || (97 ... 122).contains(byte) || (48 ... 57).contains(byte)
    }

    private static func tag(_ value: Any?) -> String? {
        guard let text = value as? String, (1 ... 64).contains(text.utf8.count),
              text.utf8.allSatisfy({ isAlphanumeric($0) || $0 == 45 || $0 == 95 })
        else { return nil }
        return text
    }

    private static func hostname(_ text: String) -> Bool {
        guard (1 ... 253).contains(text.utf8.count) else { return false }
        return text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            (1 ... 63).contains(label.utf8.count) && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { isAlphanumeric($0) || $0 == 45 }
        }
    }

    /// Go's netip parser treats malformed IPv4 literals as names. Require a round trip
    /// for IPv4 and reject scope IDs, C-string terminators and IPv4-mapped IPv6 aliases.
    private static func addressBytes(_ text: String) -> [UInt8]? {
        guard !text.utf8.contains(0), !text.utf8.contains(37) else { return nil }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            let bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return bytes.map(String.init).joined(separator: ".") == text ? bytes : nil
        }
        var v6 = in6_addr()
        guard !text.contains("."), inet_pton(AF_INET6, text, &v6) == 1 else { return nil }
        return withUnsafeBytes(of: &v6) { Array($0) }
    }

    private static func numericPeer(_ text: String) -> Bool {
        guard let bytes = addressBytes(text) else { return false }
        if bytes.count == 4 {
            return bytes[0] > 0 && bytes[0] < 224 && bytes[0] != 127 && !(bytes[0] == 169 && bytes[1] == 254)
        }
        return bytes[0] & 0xE0 == 0x20 || bytes[0] & 0xFE == 0xFC
    }

    private static func validatePeer(_ raw: Object, _ binding: CLIBinding?) throws -> String {
        guard let peer = object(raw, keys: ["type", "tag", "server", "server_port", "uuid", "flow", "packet_encoding", "tls"]),
              peer["type"] as? String == "vless", let selected = tag(peer["tag"]),
              let server = peer["server"] as? String, let peerPort = port(peer["server_port"]),
              let id = peer["uuid"] as? String, let uuid = UUID(uuidString: id),
              uuid.uuidString.lowercased() == id.lowercased(),
              peer["flow"] == nil || peer["flow"] as? String == "xtls-rprx-vision",
              peer["packet_encoding"] == nil || peer["packet_encoding"] as? String == "xudp",
              let tls = object(peer["tls"], keys: ["enabled", "server_name", "utls", "reality"]),
              enabled(tls["enabled"]), let name = tls["server_name"] as? String, hostname(name),
              let utls = object(tls["utls"], keys: ["enabled", "fingerprint"]), enabled(utls["enabled"]),
              ["firefox", "chrome", "safari", "edge", "ios", "android"].contains(utls["fingerprint"] as? String ?? ""),
              let reality = object(tls["reality"], keys: ["enabled", "public_key", "short_id"]), enabled(reality["enabled"]),
              let key = reality["public_key"] as? String, key.utf8.count == 43,
              key.utf8.allSatisfy({ isAlphanumeric($0) || $0 == 45 || $0 == 95 }),
              let decoded = Data(base64Encoded: key.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
              decoded.count == 32, decoded.contains(where: { $0 != 0 }),
              let shortID = reality["short_id"] as? String, (2 ... 16).contains(shortID.utf8.count),
              shortID.utf8.count.isMultiple(of: 2), shortID.utf8.allSatisfy(isHexDigit)
        else { throw Rejection.peer }
        if let binding {
            guard server == "127.0.0.1", peerPort == binding.relayPort else { throw Rejection.peer }
        } else if !numericPeer(server) {
            throw Rejection.peer
        }
        return selected
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (65 ... 70).contains(byte) || (97 ... 102).contains(byte)
    }

    private static func validateTun(_ raw: Object) throws -> String {
        guard let tun = object(raw, keys: ["type", "tag", "address", "auto_route", "stack", "strict_route", "dns_mode", "mtu", "route_address"]),
              let name = tag(tun["tag"]), enabled(tun["auto_route"]),
              tun["stack"] == nil || tun["stack"] as? String == "system",
              tun["strict_route"] == nil || enabled(tun["strict_route"]),
              tun["dns_mode"] == nil || tun["dns_mode"] as? String == "hijack",
              tun["mtu"] == nil || (1280 ... 9000).contains(integer(tun["mtu"]) ?? 0),
              let addresses = tun["address"] as? [String], addresses.count == 2,
              Set(addresses.compactMap(tunnelAddressFamily)) == [4, 6]
        else { throw Rejection.tun }
        if let value = tun["route_address"] {
            guard let routes = value as? [String], routes.count == 2, Set(routes) == ["0.0.0.0/0", "::/0"]
            else { throw Rejection.tun }
        }
        return name
    }

    /// These small private subnets reserve the next address for sing-tun's DNS interception.
    private static func tunnelAddressFamily(_ cidr: String) -> Int? {
        let fields = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2, let bytes = addressBytes(String(fields[0])), let last = bytes.last, last & 3 == 1
        else { return nil }
        if bytes.count == 4 {
            let isPrivate = bytes[0] == 10 || (bytes[0] == 172 && (16 ... 31).contains(bytes[1])) ||
                (bytes[0] == 192 && bytes[1] == 168)
            return isPrivate && fields[1] == "30" ? 4 : nil
        }
        return bytes[0] & 0xFE == 0xFC && fields[1] == "126" ? 6 : nil
    }

    private static func validateCLI(_ raw: Object, _ binding: CLIBinding) throws -> String {
        guard let http = object(raw, keys: ["type", "tag", "listen", "listen_port", "users", "tls"]),
              let name = tag(http["tag"]), http["listen"] as? String == "127.0.0.1", port(http["listen_port"]) == binding.proxyPort,
              let users = http["users"] as? [Object], users.count == 1,
              let user = object(users[0], keys: ["username", "password"]), user["username"] as? String == "airlock",
              let password = user["password"] as? String, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              password.rangeOfCharacter(from: .controlCharacters) == nil,
              let tls = object(http["tls"], keys: ["enabled", "certificate", "key"]), enabled(tls["enabled"]),
              let cert = tls["certificate"] as? String, let key = tls["key"] as? String,
              matchingIdentity(certificate: cert, privateKey: key)
        else { throw Rejection.listener }
        return name
    }

    private static func pem(_ text: String, labels: [String]) -> Data? {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.count >= 3,
              let label = labels.first(where: { lines.first == "-----BEGIN " + $0 + "-----" }),
              lines.last == "-----END " + label + "-----" else { return nil }
        let body = lines.dropFirst().dropLast().joined()
        guard !body.isEmpty else { return nil }
        return Data(base64Encoded: body)
    }

    private static func matchingIdentity(certificate: String, privateKey: String) -> Bool {
        guard let der = pem(certificate, labels: ["CERTIFICATE"]),
              let cert = SecCertificateCreateWithData(nil, der as CFData), let certKey = SecCertificateCopyKey(cert),
              pem(privateKey, labels: ["PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY"]) != nil
        else { return false }
        // A nil destination keychain imports the key into memory only.
        var format = SecExternalFormat.formatUnknown
        var type = SecExternalItemType.itemTypePrivateKey
        var items: CFArray?
        guard SecItemImport(Data(privateKey.utf8) as CFData, nil, &format, &type, [], nil, nil, &items) == errSecSuccess,
              let results = items as? [AnyObject], results.count == 1, CFGetTypeID(results[0]) == SecKeyGetTypeID(),
              let keys = items as? [SecKey], let publicKey = SecKeyCopyPublicKey(keys[0]),
              let observed = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let expected = SecKeyCopyExternalRepresentation(certKey, nil) as Data?
        else { return false }
        return observed == expected
    }

    private static func validateDNS(_ value: Any?, _ outbound: String) throws {
        guard let dns = object(value, keys: ["servers", "final"]),
              let servers = dns["servers"] as? [Object], servers.count == 1,
              let server = object(servers[0], keys: ["type", "tag", "server", "server_port", "path", "detour"]),
              server["type"] as? String == "https", let name = tag(server["tag"]), dns["final"] as? String == name,
              server["detour"] as? String == outbound,
              let host = server["server"] as? String, numericPeer(host) || hostname(host),
              server["server_port"] == nil || port(server["server_port"]) != nil,
              server["path"] == nil || server["path"] as? String == "/dns-query"
        else { throw Rejection.dns }
        // In the pinned engine a named DoH server with an explicit detour is passed
        // to VLESS for remote resolution. A domain_resolver here would change that.
    }

    private static func validateRoute(_ value: Any?, _ outbound: String, _ inbounds: Set<String>) throws {
        guard let route = object(value, keys: ["rules", "final", "auto_detect_interface"]),
              route["final"] as? String == outbound,
              route["auto_detect_interface"] == nil || enabled(route["auto_detect_interface"]),
              let rules = route["rules"] as? [Object], let first = rules.first,
              object(first, keys: ["port", "action"]) != nil, port(first["port"]) == 53,
              ["hijack-dns", "reject"].contains(first["action"] as? String ?? "")
        else { throw Rejection.route }
        for rule in rules.dropFirst() {
            let keys: Set<String>
            switch rule["action"] as? String {
            case "reject":
                keys = ["action", "inbound", "port", "network", "ip_is_private", "method"]
                guard rule["method"] == nil || ["default", "drop"].contains(rule["method"] as? String ?? "")
                else { throw Rejection.route }
            case "route":
                keys = ["action", "inbound", "port", "network", "ip_is_private", "outbound"]
                guard rule["outbound"] as? String == outbound else { throw Rejection.route }
            default:
                throw Rejection.route
            }
            guard object(rule, keys: keys) != nil,
                  rule["port"] == nil || port(rule["port"]) != nil,
                  rule["network"] == nil || ["tcp", "udp"].contains(rule["network"] as? String ?? ""),
                  rule["ip_is_private"] == nil || enabled(rule["ip_is_private"]),
                  rule["inbound"] == nil || inbounds.contains(rule["inbound"] as? String ?? "")
            else { throw Rejection.route }
        }
    }

    /// Foundation discards duplicate members. Counting key separators in validated JSON
    /// and comparing with the decoded tree detects duplicates even inside discarded values.
    private static func checkJSONTokens(_ data: Data) throws -> Int {
        var memberCount = 0
        var depth = 0
        var inString = false
        var escaped = false
        var previous: UInt8 = 0
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    inString = false
                }
                continue
            }
            switch byte {
            case 9, 10, 13, 32: continue
            case 34: inString = true
            case 58: memberCount += 1
            case 91, 123:
                depth += 1
                guard depth <= 16 else { throw Rejection.json }
            case 93, 125:
                guard previous != 44, depth > 0 else { throw Rejection.json }
                depth -= 1
            case 101 where (48 ... 57).contains(previous): throw Rejection.json // fractional/exponent numbers are outside the schema
            case 44, 45, 48 ... 57, 97, 101, 102, 108, 110, 114, 115, 116, 117: break
            default: throw Rejection.json
            }
            previous = byte
        }
        guard depth == 0, !inString else { throw Rejection.json }
        return memberCount
    }

    private static func countMembers(_ value: Any) -> Int {
        if let object = value as? Object { return object.values.reduce(object.count) { $0 + countMembers($1) } }
        if let array = value as? [Any] { return array.reduce(0) { $0 + countMembers($1) } }
        return 0
    }
}
#endif
