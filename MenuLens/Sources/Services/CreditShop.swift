import StoreKit

/// Credits sold as StoreKit 2 consumables. Apple charges; our server verifies
/// the signed transaction and adds the credits (POST /purchase, idempotent per
/// transaction); only then is the transaction finished. Unfinished ones (app
/// killed, offline, signed out) are retried on the next launch and sign-in.
@MainActor
final class CreditShop: ObservableObject {
    static let shared = CreditShop()

    /// Product ids and the credits each adds — must match
    /// backend/src/purchase.mjs. Prices live in App Store Connect.
    static let packs: [(id: String, credits: Int)] = [
        ("ai.xiangyang.MenuLens.credits.100", 100),
        ("ai.xiangyang.MenuLens.credits.500", 500),
        ("ai.xiangyang.MenuLens.credits.2000", 2000),
    ]

    @Published private(set) var products: [Product] = []
    @Published private(set) var loading = false
    /// Product id of the purchase in progress.
    @Published private(set) var buying: String?
    /// The outcome of the last purchase, for the sheet ("110 credits added").
    @Published var message: String?
    @Published var problem: String?

    private let account = AccountStore.shared
    private var updates: Task<Void, Never>?

    private init() {
        // Purchases that complete outside the sheet (Ask to Buy, a retry
        // after a crash, another device).
        updates = Task { [weak self] in
            for await result in Transaction.updates { await self?.handle(result) }
        }
        retryUnfinished()
    }

    func retryUnfinished() {
        Task { [weak self] in
            for await result in Transaction.unfinished { await self?.handle(result) }
        }
    }

    func loadProducts() async {
        guard products.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let order = Self.packs.map(\.id)
            products = try await Product.products(for: order)
                .sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
            if products.isEmpty { problem = L("shop.unavailable") }
        } catch {
            problem = L("shop.loadFailed", error.localizedDescription)
        }
    }

    func buy(_ product: Product) async {
        problem = nil
        message = nil
        guard account.isSignedIn else { problem = L("shop.signInFirst"); return }
        guard let token = await account.purchaseToken() else { problem = L("shop.noServer"); return }
        buying = product.id
        defer { buying = nil }
        do {
            switch try await product.purchase(options: [.appAccountToken(token)]) {
            case let .success(result): await handle(result)
            case .pending: message = L("shop.pending")
            case .userCancelled: break
            @unknown default: break
            }
        } catch {
            problem = L("shop.purchaseFailed", error.localizedDescription)
        }
    }

    /// Credits a transaction on the server, then finishes it. Left unfinished
    /// on any failure, so StoreKit hands it to us again later.
    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case let .verified(transaction) = result else {
            problem = L("shop.unverified")
            return
        }
        guard Self.credits(of: transaction.productID) != nil else { return }
        guard account.isSignedIn else {
            problem = L("shop.notCredited", L("shop.signInFirst"))
            return
        }
        do {
            let request = Backend.request(
                "purchase", method: "POST", token: account.sessionToken,
                json: ["jws": result.jwsRepresentation]
            )
            let reply = try await Backend.send(request)
            if let total = reply["totalCredits"] as? NSNumber { account.applyBalance(total.intValue) }
            // credited == false: this transaction was credited before (a
            // retry) — finishing it is still right.
            await transaction.finish()
            if reply["credited"] as? Bool == true, let credits = reply["credits"] as? NSNumber {
                message = L("shop.credited", credits.intValue)
            }
            Task { await account.refreshCredits() }
        } catch {
            problem = L("shop.notCredited", error.localizedDescription)
        }
    }

    /// Credits the pack adds, nil for a product that isn't ours.
    static func credits(of id: String) -> Int? {
        packs.first { $0.id == id }?.credits
    }
}
