import StoreKitTest
import SwiftUI
import XCTest
@testable import MenuLens

/// The membership: Products.storekit's three plans (and, run from Xcode, that
/// StoreKit serves them), the server's `subscription` object, and the shop
/// with the subscription store above the packs / the account card's badge
/// and meter (left on screen `FM_HOLD` seconds, for screenshots).
///
///   TEST_RUNNER_FM_LANG=zh-Hans TEST_RUNNER_FM_HOLD=8 \
///     xcodebuild test -scheme MenuLens -destination '…' -only-testing:MenuLensTests/SubscriptionTests
///
/// Signed in on made-up account data (`AccountStore.forceDemo`, the test's
/// `-demoUsage`): nothing account-related goes to the server, and the
/// membership state is applied directly.
@MainActor
final class SubscriptionTests: XCTestCase {
    /// The plans as Products.storekit defines them (what Xcode's StoreKit
    /// testing serves): ids, prices, periods, one group.
    func testStoreKitFileDefinesThePlans() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Products", withExtension: "storekit"))
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let groups = try XCTUnwrap(file["subscriptionGroups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        let plans = try XCTUnwrap(groups[0]["subscriptions"] as? [[String: Any]])
        XCTAssertEqual(plans.map { $0["productID"] as? String }, CreditShop.subscriptions)
        XCTAssertEqual(plans.map { $0["displayPrice"] as? String }, ["4.00", "10.00", "30.00"])
        XCTAssertEqual(plans.map { $0["recurringSubscriptionPeriod"] as? String }, ["P1M", "P3M", "P1Y"])
        XCTAssertTrue(plans.allSatisfy { $0["type"] as? String == "RecurringSubscription" })
    }

    /// The plans load from StoreKit. Needs Xcode's StoreKit test server:
    /// run from Xcode (Product → Test). Under `xcodebuild` SKTestSession
    /// can't install its configuration (SKInternalErrorDomain 3 in the
    /// simulator log) and StoreKit asks the real App Store instead, which
    /// only knows the plans once they exist in App Store Connect.
    func testPlansLoad() async throws {
        let session = try SKTestSession(configurationFileNamed: "Products")
        session.disableDialogs = true
        session.clearTransactions()

        let products = try await Product.products(for: CreditShop.subscriptions)
        if products.isEmpty {
            throw XCTSkip("No StoreKit test server (xcodebuild) and the plans aren't in App Store Connect yet")
        }
        let byID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        XCTAssertEqual(Set(byID.keys), Set(CreditShop.subscriptions))
        XCTAssertEqual(CreditShop.subscriptions.map { byID[$0]?.displayPrice }, ["$4.00", "$10.00", "$30.00"])
        let periods = CreditShop.subscriptions.compactMap { byID[$0]?.subscription?.subscriptionPeriod }
        XCTAssertEqual(periods.map(\.value), [1, 3, 1])
        XCTAssertEqual(periods.map(\.unit), [.month, .month, .year])
        // One group: switching plans is a crossgrade, not a second subscription.
        XCTAssertEqual(Set(products.compactMap { $0.subscription?.subscriptionGroupID }).count, 1)
        XCTAssertTrue(products.allSatisfy { $0.type == .autoRenewable })
    }

    func testMembershipParses() throws {
        let json: [String: Any] = [
            "active": true, "productId": "ai.xiangyang.MenuLens.sub.yearly", "expiresAt": "2027-10-17T08:00:00.000Z",
            "autoRenew": NSNull(), "monthUsedCredits": 612, "monthFairUseCredits": 600,
        ]
        let membership = try XCTUnwrap(Membership(json: json))
        XCTAssertTrue(membership.active)
        XCTAssertNil(membership.autoRenew)
        XCTAssertEqual(membership.expiresAt, ISO8601DateFormatter().date(from: "2027-10-17T08:00:00Z"))
        XCTAssertTrue(membership.overFairUse)
        XCTAssertNil(Membership(json: nil)) // a server from before subscriptions
        let lapsed = try XCTUnwrap(Membership(json: ["active": false, "expiresAt": NSNull(), "monthUsedCredits": 0]))
        XCTAssertFalse(lapsed.overFairUse)
        XCTAssertEqual(lapsed.monthFairUseCredits, CreditShop.fairUseCredits)
    }

    /// The shop with the paywall; `FM_MEMBER=1` shows it as a member
    /// (status, manage button); `FM_SCREEN=card` shows Settings' account
    /// card instead (badge and fair-use meter, `FM_OVER=1` past the cap).
    /// `FM_READY=<path>`: created once the screen is up (for screenshots).
    func testPaywallRenders() async throws {
        let env = ProcessInfo.processInfo.environment
        let session = try SKTestSession(configurationFileNamed: "Products")
        session.disableDialogs = true
        session.clearTransactions()

        Localization.shared.setLanguage(AppLanguage(rawValue: env["FM_LANG"] ?? "en") ?? .english)
        let account = AccountStore.shared
        AccountStore.forceDemo = true
        defer { AccountStore.forceDemo = false }
        account.setSession("placeholder-session")
        account.applyBalance(640)
        if env["FM_MEMBER"] == "1" || env["FM_SCREEN"] == "card" {
            account.applyMembership([
                "active": true, "productId": CreditShop.subscriptions[2], "autoRenew": true,
                "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(330 * 86400)),
                "monthUsedCredits": env["FM_OVER"] == "1" ? 612 : 87, "monthFairUseCredits": 600,
            ])
        }

        let window = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first)
        let root: AnyView = env["FM_SCREEN"] == "card"
            ? AnyView(NavigationStack {
                Form { Section(L("settings.account.header")) { CreditsCard(account: account, onBuy: {}, onRedeem: {}) } }
                    .navigationTitle(L("settings.title"))
                    .navigationBarTitleDisplayMode(.inline)
            })
            : AnyView(ShopView())
        let host = UIHostingController(rootView: root)
        // On top of whatever an earlier test left on screen (ShopTests keeps its sheet).
        var top = try XCTUnwrap(window.rootViewController)
        while let presented = top.presentedViewController { top = presented }
        top.present(host, animated: false)

        try await Task.sleep(for: .seconds(3))
        XCTAssertGreaterThan(host.view.bounds.height, 0)
        XCTAssertNotNil(host.view.window)
        // Screenshot scripts wait for this file, then `simctl io … screenshot`.
        if let ready = env["FM_READY"] { FileManager.default.createFile(atPath: ready, contents: Data()) }
        try await Task.sleep(for: .seconds(Double(env["FM_HOLD"] ?? "1") ?? 1))
        account.signOut()
        host.dismiss(animated: false)
    }
}
