import Foundation
import XCTest
@testable import DeusLinks

final class AppLinksTests: XCTestCase {
    func testTaildropTargetsTheForkScheme() throws {
        let input = try XCTUnwrap(URL(string: "sing-box://taildrop"))
        XCTAssertEqual(AppLinks.replacingScheme(in: input, with: "deus-airlock")?.absoluteString, "deus-airlock://taildrop")
    }

    func testImportKeepsItsEncodedRemoteAddressAndName() throws {
        let input = try XCTUnwrap(URL(string: "sing-box://import-remote-profile?url=https%3A%2F%2Fexample.com%2Fa%3Fx%3D1%26y%3D2&name=Claude%20profile#fragment"))
        XCTAssertEqual(AppLinks.replacingScheme(in: input, with: "deus-airlock")?.absoluteString,
                       "deus-airlock://import-remote-profile?url=https%3A%2F%2Fexample.com%2Fa%3Fx%3D1%26y%3D2&name=Claude%20profile#fragment")
    }

    func testInvalidSchemeDoesNotFallBackToAnotherApplication() throws {
        let input = try XCTUnwrap(URL(string: "sing-box://taildrop"))
        for scheme in ["", "1deus", "deus://", "de us"] {
            XCTAssertNil(AppLinks.replacingScheme(in: input, with: scheme))
        }
    }
}
