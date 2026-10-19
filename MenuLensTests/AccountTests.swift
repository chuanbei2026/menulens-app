import XCTest
@testable import MenuLens

/// Which account a session belongs to is read from its own claims: the
/// account screen shows the device account or the Apple account by it.
@MainActor
final class AccountTests: XCTestCase {
    private func token(_ claims: [String: Any]) -> String {
        func part(_ object: Any) -> String {
            (try! JSONSerialization.data(withJSONObject: object)).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(part(["alg": "HS256", "typ": "JWT"])).\(part(claims)).signature"
    }

    func testClaimsOfDeviceAndAppleSessions() throws {
        let exp = Date().timeIntervalSince1970 + 30 * 86400
        let device = try XCTUnwrap(AccountStore.claims(of: token(["iss": "foreignmenu", "sub": "anon:6fad3ee0-be08", "exp": exp])))
        XCTAssertEqual(device.sub, "anon:6fad3ee0-be08")
        XCTAssertEqual(device.exp, exp, accuracy: 1)
        // Subjects whose JSON needs base64url's "-" / "_" and no padding.
        let apple = try XCTUnwrap(AccountStore.claims(of: token(["sub": "apple:001234.5f>?~", "exp": exp])))
        XCTAssertTrue(apple.sub.hasPrefix("apple:"))
        XCTAssertNil(AccountStore.claims(of: ""))
        XCTAssertNil(AccountStore.claims(of: "not.a-token"))
    }
}
