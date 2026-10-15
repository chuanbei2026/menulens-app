import StoreKitTest
import SwiftUI
import XCTest
@testable import MenuLens

/// The credit shop with StoreKit served from Products.storekit: the three
/// packs load in our order and the sheet shows them (left on screen for a few
/// seconds, for screenshots).
///
///   TEST_RUNNER_FM_SESSION_TOKEN=<dev token> [TEST_RUNNER_FM_LANG=zh-Hans] \
///     xcodebuild test -scheme MenuLens -destination '…' -only-testing:MenuLensTests/ShopTests
///
/// Buying is not exercised here: on a headless simulator `product.purchase`
/// raises the sandbox account sheet and `SKTestSession.buyProduct` answers
/// notEntitled. Run the app from Xcode (the scheme carries Products.storekit)
/// to buy; the server then rejects the Xcode-signed transaction with 400
/// bad_jws and the shop leaves it unfinished, or use a Sandbox account on a
/// device for a purchase the server credits.
@MainActor
final class ShopTests: XCTestCase {
    func testPacksLoadAndShow() async throws {
        let env = ProcessInfo.processInfo.environment
        let session = try SKTestSession(configurationFileNamed: "Products")
        session.disableDialogs = true
        session.clearTransactions()

        Localization.shared.setLanguage(AppLanguage(rawValue: env["FM_LANG"] ?? "en") ?? .english)
        if let token = env["FM_SESSION_TOKEN"], !token.isEmpty {
            AccountStore.shared.setSession(token)
            await AccountStore.shared.refreshCredits()
        }

        let window = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first)
        window.rootViewController?.present(UIHostingController(rootView: ShopView()), animated: false)

        let shop = CreditShop.shared
        await shop.loadProducts()
        XCTAssertEqual(shop.products.map(\.id), CreditShop.packs.map(\.id))
        XCTAssertEqual(shop.products.map(\.displayPrice), ["$0.99", "$4.99", "$19.99"])
        XCTAssertNil(shop.problem)
        try await Task.sleep(for: .seconds(8))
    }
}
