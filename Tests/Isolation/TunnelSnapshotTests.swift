import NetworkExtension
import XCTest
@testable import DeusIsolation

final class TunnelSnapshotTests: XCTestCase {
    private enum Fault: Error { case rejected }
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func snapshot(_ proto: NETunnelProviderProtocol, protected: Bool = true) throws -> TunnelSnapshot {
        try TunnelSnapshot(directory: directory, configuration: proto, protected: protected)
    }

    func testRejectedStartAndReloadPreserveLastSuccessfulState() throws {
        let proto = NETunnelProviderProtocol()
        TunnelSnapshot.identify(proto)
        let store = try snapshot(proto)
        let good = Data([1]), bad = Data([2])
        var service: Data?
        func activate(_ bytes: Data, fail: Bool) throws {
            let previous = service
            try store.activate(bytes, apply: {
                service = bytes
                if fail { throw Fault.rejected }
            }, restore: { service = previous })
        }
        XCTAssertThrowsError(try activate(bad, fail: true))
        XCTAssertNil(try store.load())
        try activate(good, fail: false)
        XCTAssertThrowsError(try activate(bad, fail: true))
        XCTAssertEqual(service, good)
        XCTAssertEqual(try snapshot(proto).load(), good)
    }

    func testPolicyScopesDoNotShareSnapshotsOrTrustTheLegacyFile() throws {
        try Data([99]).write(to: directory.appendingPathComponent("start_options.plist"))
        let one = NETunnelProviderProtocol(), two = NETunnelProviderProtocol()
        XCTAssertThrowsError(try snapshot(one))
        TunnelSnapshot.identify(one)
        let first = try snapshot(one)
        XCTAssertNil(try first.load())
        try first.activate(Data([1]), apply: {}, restore: {})
        TunnelSnapshot.identify(two)
        XCTAssertNil(try snapshot(two).load())
        XCTAssertNil(try snapshot(one, protected: false).load())
        TunnelSnapshot.identify(one)
        XCTAssertEqual(try snapshot(one).load(), Data([1]))
    }

    func testDiskCommitFailureRestoresService() throws {
        let proto = NETunnelProviderProtocol()
        TunnelSnapshot.identify(proto)
        let store = try snapshot(proto)
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        var running = "old"
        XCTAssertThrowsError(try store.activate(Data(), apply: { running = "new" }, restore: { running = "old" }))
        XCTAssertEqual(running, "old")
    }
}
