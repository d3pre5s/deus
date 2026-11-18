import Foundation
import XCTest
@testable import DeusIsolation

final class AppIdentityTests: XCTestCase {
    private func fixture() throws -> URL {
        let temporaryRoot = ProcessInfo.processInfo.environment["DEUS_TEST_TMPDIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: temporaryRoot).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("Claude fixture")
        // Copy bytes only, not the system binary's restricted filesystem flags.
        try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", "--identifier", "io.github.d3pre5s.deusairlock.fixture", executable.path]
        try signer.run()
        signer.waitUntilExit()
        XCTAssertEqual(signer.terminationStatus, 0)
        return executable
    }

    func testReadsRealSignatureAndCanonicalExecutable() throws {
        let executable = try fixture()
        let identity = try DeusAppIdentity.inspect(executable)
        XCTAssertEqual(identity.signingIdentifier, "io.github.d3pre5s.deusairlock.fixture")
        XCTAssertEqual(identity.executablePath, executable.resolvingSymlinksInPath().path)
        XCTAssertFalse(identity.designatedRequirement.isEmpty)
        let rule = try XCTUnwrap(DeusPerAppPolicy(identities: [identity]).makeAppRules().first)
        XCTAssertEqual(rule.matchPath, identity.executablePath)
    }

    func testTamperedExecutableCannotBecomeASelectedIdentity() throws {
        let executable = try fixture()
        var bytes = try Data(contentsOf: executable)
        bytes[4096] ^= 0xff
        try bytes.write(to: executable)
        XCTAssertThrowsError(try DeusAppIdentity.inspect(executable))
    }

    func testScriptDoesNotBecomeTheIdentityOfItsInterpreter() throws {
        let executable = try fixture()
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        XCTAssertThrowsError(try DeusAppIdentity.inspect(executable))
    }
}
