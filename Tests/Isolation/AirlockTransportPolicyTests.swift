import CryptoKit
import Foundation
import XCTest
@testable import DeusIsolation

final class AirlockTransportPolicyTests: XCTestCase {
    private typealias Binding = AirlockTransportPolicy.CLIBinding

    // All addresses are examples. This profile never opens a socket.
    private let profile = #"""
    {
      "log": {"level": "warn"},
      "inbounds": [
        {"type":"tun","tag":"apps","address":["172.19.0.1/30","fdfe:dcba:9876::1/126"],"auto_route":true,"stack":"system"}
      ],
      "outbounds": [
        {"type":"vless","tag":"chosen","server":"192.0.2.1","server_port":443,
         "uuid":"00000000-0000-4000-8000-000000000001","flow":"xtls-rprx-vision",
         "tls":{"enabled":true,"server_name":"peer.example",
                "utls":{"enabled":true,"fingerprint":"firefox"},
                "reality":{"enabled":true,"public_key":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE","short_id":"abcd"}}}
      ],
      "dns":{"servers":[{"type":"https","tag":"resolver","server":"resolver.example","server_port":443,
                         "path":"/dns-query","detour":"chosen"}],"final":"resolver"},
      "route":{"rules":[{"port":53,"action":"hijack-dns"}],"final":"chosen"}
    }
    """#

    private func changing(_ original: String, _ replacement: String, in config: String? = nil,
                          file: StaticString = #filePath, line: UInt = #line) -> String {
        let source = config ?? profile
        XCTAssertTrue(source.contains(original), file: file, line: line)
        return source.replacingOccurrences(of: original, with: replacement)
    }

    func testSelectedNumericPeerReceivesBothFamiliesAndDetouredDNS() throws {
        try AirlockTransportPolicy.validate(profile)
        try AirlockTransportPolicy.validate(changing("192.0.2.1", "2001:db8::7"))
        let rules = #"{"port":53,"action":"hijack-dns"},{"port":25,"action":"reject"},{"inbound":"apps","action":"route","outbound":"chosen"}"#
        try AirlockTransportPolicy.validate(changing(#"{"port":53,"action":"hijack-dns"}"#, rules))
        try AirlockTransportPolicy.validate(changing(#""action":"hijack-dns""#, #""action":"reject""#))
        let fullRoutes = #""stack":"system","route_address":["::/0","0.0.0.0/0"]"#
        try AirlockTransportPolicy.validate(changing(#""stack":"system""#, fullRoutes))
    }

    func testReloadAllowsRoutingPolicyChangesOnlyForTheSamePeer() throws {
        try AirlockTransportPolicy.checkReload(changing(#""level": "warn""#, #""level": "error""#), replacing: profile)
        // A reordered JSON object still describes the same selected peer.
        try AirlockTransportPolicy.checkReload(changing(#""type":"vless","tag":"chosen""#, #""tag":"chosen","type":"vless""#),
                                               replacing: profile)
        let replacements = [
            ("192.0.2.1", "192.0.2.2"),
            (#""server":"192.0.2.1","server_port":443"#, #""server":"192.0.2.1","server_port":9443"#),
            ("peer.example", "different.example"),
            ("00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002"),
            ("AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE", "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI"),
        ]
        for (old, new) in replacements {
            let other = changing(old, new)
            try AirlockTransportPolicy.validate(other)
            XCTAssertThrowsError(try AirlockTransportPolicy.checkReload(other, replacing: profile))
        }
        XCTAssertThrowsError(try AirlockTransportPolicy.checkReload(profile, replacing: "{}"))
        XCTAssertThrowsError(try AirlockTransportPolicy.checkReload(changing(#""auto_route":true"#, #""auto_route":false"#), replacing: profile))
    }

    func testRequiresOneAuthenticatedNumericPeerAndRejectsLocalAliases() {
        for server in ["peer.example", "127.0.0.1", "127.0.0.2", "::1", "::ffff:127.0.0.1", "::", "0.0.0.0",
                       "224.0.0.1", "ff02::1", "fe80::1%en0", "192.000.2.1", #"192.0.2.1\u0000.example"#] {
            XCTAssertThrowsError(try AirlockTransportPolicy.validate(changing("192.0.2.1", server)), server)
        }
        for (old, new) in [
            (#""type":"vless""#, #""type":"direct""#),
            (#""type":"vless""#, #""type":"selector""#),
            (#""type":"vless""#, #""type":"vless","detour":"other""#),
            (#""type":"vless""#, #""type":"vless","transport":{"type":"ws"}"#),
            (#""type":"vless""#, #""type":"vless","domain_resolver":"local""#),
            (#""type":"vless""#, #""type":"vless","fallback_network_type":"wifi""#),
            (#""flow":"xtls-rprx-vision""#, #""flow":"other""#),
            (#""server_port":443"#, #""server_port":true"#),
            (#""server_port":443"#, #""server_port":0"#),
            (#""server_port":443"#, #""server_port":65536"#),
            ("00000000-0000-4000-8000-000000000001", "arbitrary identifier"),
            (#""enabled":true"#, #""enabled":1"#),
            (#""utls":{"enabled":true"#, #""utls":{"enabled":false"#),
            (#""reality":{"enabled":true"#, #""reality":{"enabled":false"#),
            (#""tls":{"enabled":true"#, #""tls":{"enabled":true,"insecure":true"#),
            (#""short_id":"abcd""#, #""short_id":"not-hex""#),
            ("AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE", "bad-key"),
            (#""outbounds": ["#, #""outbounds": [{"type":"direct","tag":"extra"},"#),
        ] {
            XCTAssertThrowsError(try AirlockTransportPolicy.validate(changing(old, new)), new)
        }
    }

    func testRefusesBypassRoutesControlImportsAndAdditionalListeners() {
        for (old, new) in [
            (#""inbounds": ["#, #""inbounds": [{"type":"mixed","listen":"127.0.0.1","listen_port":15000},"#),
            (#""type":"tun""#, #""type":"http""#),
            (#""auto_route":true"#, #""auto_route":false"#),
            (#""auto_route":true"#, #""auto_route":true,"dns_mode":"disabled""#),
            (#""stack":"system""#, #""stack":"system","route_address":["192.0.2.0/24","::/0"]"#),
            (#""stack":"system""#, #""stack":"system","route_exclude_address":["0.0.0.0/0"]"#),
            (#""stack":"system""#, #""stack":"system","route_address_set":["subset"]"#),
            (#""stack":"system""#, #""stack":"system","platform":{"http_proxy":{"enabled":true}}"#),
            (#""stack":"system""#, #""stack":"system","exclude_package":["any"]"#),
            (#","fdfe:dcba:9876::1/126""#, ""),
            ("172.19.0.1/30", "0.0.0.0/0"),
            (#""log": {"level": "warn"}"#, #""experimental":{"clash_api":{"external_controller":"127.0.0.1:9090"}}"#),
            (#""log": {"level": "warn"}"#, #""ntp":{"enabled":true}"#),
            (#""log": {"level": "warn"}"#, #""endpoints":[{"type":"wireguard"}]"#),
            (#""log": {"level": "warn"}"#, #""services":[{"type":"ssm-api"}]"#),
            (#""log": {"level": "warn"}"#, #""log":{"output":"/tmp/external"}"#),
            (#""rules":["#, #""rule_set":[],"rules":["#),
            (#""rules":["#, #""default_domain_resolver":"local","rules":["#),
            (#""final":"chosen""#, #""final":"direct""#),
            (#""port":53"#, #""port":5353"#),
            (#""port":53"#, #""port":53,"network":"tcp""#),
            (#""port":53"#, #""port":53,"override_address":"127.0.0.1""#),
            (#""port":53"#, #""port":53,"type":"logical""#),
        ] {
            XCTAssertThrowsError(try AirlockTransportPolicy.validate(changing(old, new)), new)
        }
        let hijack = #"{"port":53,"action":"hijack-dns"}"#
        for rule in [
            #"{"action":"route","outbound":"chosen","override_port":25}"#,
            #"{"action":"route","outbound":"direct"}"#,
            #"{"action":"route-options","override_address":"external.example"}"#,
            #"{"action":"resolve","server":"system"}"#,
            #"{"action":"route","inbound":"other","outbound":"chosen"}"#,
        ] {
            XCTAssertThrowsError(try AirlockTransportPolicy.validate(changing(hijack, hijack + "," + rule)), rule)
        }
        let shadow = #"{"action":"route","outbound":"chosen"},"# + hijack
        XCTAssertThrowsError(try AirlockTransportPolicy.validate(changing(hijack, shadow)))
    }

    func testDNSRequiresOneExplicitDetourAndNoBootstrapFallback() {
        for (old, new) in [
            (#""type":"https""#, #""type":"local""#),
            (#""detour":"chosen""#, #""detour":"""#),
            (#","detour":"chosen""#, ""),
            (#""detour":"chosen""#, #""detour":"direct""#),
            (#""detour":"chosen""#, #""detour":"chosen","domain_resolver":"system""#),
            (#""detour":"chosen""#, #""detour":"chosen","tls":{"insecure":true}"#),
            (#""final":"resolver""#, #""final":"other""#),
            (#""final":"resolver""#, #""final":"resolver","rules":[{"action":"evaluate","server":"other"}]"#),
            (#""servers":["#, #""servers":[{"type":"local","tag":"bootstrap"},"#),
        ] {
            XCTAssertThrowsError(try AirlockTransportPolicy.validate(changing(old, new)), new)
        }
    }

    func testRejectsDuplicateIncludingEscapedKeysAndInvalidJSONTypes() {
        for (old, new) in [
            (#""type":"vless""#, #""type":"direct","type":"vless""#),
            (#""outbounds": ["#, #""outbounds":[],"\u006futbounds": ["#),
            (#""detour":"chosen""#, #""detour":"other","detour":"chosen""#),
            (#""enabled":true"#, #""enaBled":true"#),
            (#""port":53"#, #""port":53.0"#),
            (#""level": "warn""#, #""level":null"#),
        ] {
            XCTAssertThrowsError(try AirlockTransportPolicy.validate(changing(old, new)), new)
        }
        for invalid in ["[]", "false", "{", profile + "{}"] {
            XCTAssertThrowsError(try AirlockTransportPolicy.validate(invalid))
        }
    }

    // Generate a disposable test-only TLS identity; no installed credentials are read.
    private func cliConfig(keyOverride: String? = nil) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("airlock-policy-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("key.pem")
        let certificate = directory.appendingPathComponent("cert.pem")
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        tool.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                          "-subj", "/CN=Airlock Offline Fixture", "-keyout", key.path, "-out", certificate.path]
        tool.standardOutput = FileHandle.nullDevice
        tool.standardError = FileHandle.nullDevice
        try tool.run()
        tool.waitUntilExit()
        guard tool.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        let listener: [String: Any] = [
            "type": "http", "tag": "cli", "listen": "127.0.0.1", "listen_port": 18443,
            "users": [["username": "airlock", "password": UUID().uuidString]],
            "tls": ["enabled": true, "certificate": try String(contentsOf: certificate, encoding: .utf8),
                    "key": try keyOverride ?? String(contentsOf: key, encoding: .utf8)] as [String: Any],
        ]
        let encoded = try JSONSerialization.data(withJSONObject: listener, options: [.sortedKeys])
        let wrappedListener = try XCTUnwrap(String(bytes: encoded, encoding: .utf8))
        let local = changing(#""server":"192.0.2.1","server_port":443"#, #""server":"127.0.0.1","server_port":19443"#)
        return changing(#""inbounds": ["#, #""inbounds": ["# + wrappedListener + ",", in: local)
    }

    func testOnlyExplicitProvisioningCanOpenTheOneTLSListener() throws {
        let config = try cliConfig()
        XCTAssertThrowsError(try AirlockTransportPolicy.validate(config))
        let binding = try Binding(config: config, proxyPort: 18443, relayPort: 19443)
        try AirlockTransportPolicy.validate(config, binding: binding)
        XCTAssertEqual(Set(binding.descriptor.keys), ["sha256", "proxyPort", "relayPort"])
        let expected = SHA256.hash(data: Data(config.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(binding.descriptor["sha256"] as? String, expected)
        let restored = try Binding(descriptor: binding.descriptor)
        try AirlockTransportPolicy.validate(config, binding: restored)
        try AirlockTransportPolicy.checkReload(config, replacing: config, binding: restored)
        XCTAssertThrowsError(try AirlockTransportPolicy.checkReload(config + "\n", replacing: config, binding: restored))
        XCTAssertThrowsError(try AirlockTransportPolicy.checkReload(config, replacing: config + "\n", binding: restored))
        XCTAssertThrowsError(try AirlockTransportPolicy.validate(config + "\n", binding: restored))
        XCTAssertThrowsError(try AirlockTransportPolicy.validate(profile, binding: restored))
        XCTAssertThrowsError(try Binding(config: config, proxyPort: 18444, relayPort: 19443))
        XCTAssertThrowsError(try Binding(config: config, proxyPort: 18443, relayPort: 19444))
        XCTAssertThrowsError(try Binding(config: config, proxyPort: 18443, relayPort: 18443))
        var bad = binding.descriptor
        for value: Any in [0, -1, 65536, "19443", true, 19443.5] as [Any] {
            bad["relayPort"] = value
            XCTAssertThrowsError(try Binding(descriptor: bad))
        }
        bad = binding.descriptor
        bad["sha256"] = "invalid"
        XCTAssertThrowsError(try Binding(descriptor: bad))
        bad = binding.descriptor
        bad["unknown"] = "extra"
        XCTAssertThrowsError(try Binding(descriptor: bad))
    }

    func testProvisioningRejectsAdditionalProtocolsUnpinnedAddressesAndBrokenIdentity() throws {
        let config = try cliConfig()
        for (old, new) in [
            (#""type":"http""#, #""type":"mixed""#),
            (#""type":"http""#, #""type":"socks""#),
            (#""type":"http""#, #""type":"http","set_system_proxy":true"#),
            (#""listen":"127.0.0.1""#, #""listen":"0.0.0.0""#),
            (#""server":"127.0.0.1""#, #""server":"192.0.2.1""#),
            (#""users":["#, #""users":[{"username":"extra","password":"extra"},"#),
            (#""username":"airlock""#, #""username":"""#),
            (#""password":"#, #""invalid":"#),
            (#""listen_port":18443"#, #""listen_port":19443"#),
            (#""certificate":"#, #""certificate_path":"#),
            (#""key":"#, #""key_path":"#),
            ("BEGIN CERTIFICATE", "BEGIN OTHER"),
            ("PRIVATE KEY", "OTHER KEY"),
            (#""enabled":true"#, #""enabled":false"#),
        ] {
            let mutated = changing(old, new, in: config)
            XCTAssertThrowsError(try Binding(config: mutated, proxyPort: 18443, relayPort: 19443), old)
        }
        let mismatched = try cliConfig(keyOverride: P256.Signing.PrivateKey().pemRepresentation)
        XCTAssertThrowsError(try Binding(config: mismatched, proxyPort: 18443, relayPort: 19443))
        XCTAssertThrowsError(try Binding(config: profile, proxyPort: 18443, relayPort: 19443))
    }
}
