import StoreKit

/// Credits sold as StoreKit 2 consumables. Apple charges; our server verifies
/// the signed transaction and adds the credits (POST /purchase, idempotent per
/// transaction); only then is the transaction finished. Unfinished ones (app
/// killed, offline, no session yet) are retried on the next launch and sign-in.
///
/// App Store Offer Codes for the packs (our giveaways since 1.1 (4); the app
/// has no codes of its own) arrive the same way, through `Transaction.updates`
/// — redeemed in ShopView's sheet or in the App Store app — usually at price 0
/// and without our appAccountToken; the server credits them like a purchase.
///
/// The membership (an auto-renewable subscription, bought in ShopView's
/// SubscriptionStoreView) works the same way: its transactions go to POST
/// /subscription, and the current entitlement is sent again on every return
/// to the foreground, so renewals and lapses reach the server even without
/// App Store Server Notifications.
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

    /// The membership's three plans, one subscription group — must match
    /// backend/src/subscription.mjs. Shown shortest first.
    nonisolated static let subscriptions = [
        "ai.xiangyang.MenuLens.sub.monthly",
        "ai.xiangyang.MenuLens.sub.quarterly",
        "ai.xiangyang.MenuLens.sub.yearly",
    ]
    /// What the membership gives, for the pitch before the server has
    /// answered (backend config: SUBSCRIBER_MONTHLY_FAIR_USE / _GRANT).
    nonisolated static let fairUseCredits = 600
    nonisolated static let monthlyGrantCredits = 50

    @Published private(set) var products: [Product] = []
    /// The membership plans, once StoreKit has them. Empty where they
    /// aren't offered: the shop then shows the pitch without plans rather
    /// than StoreKit's full-size "unavailable" view.
    @Published private(set) var plans: [Product] = []
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
            plans = (try? await Product.products(for: Self.subscriptions)) ?? []
        } catch {
            problem = L("shop.loadFailed", error.localizedDescription)
        }
    }

    func buy(_ product: Product) async {
        problem = nil
        message = nil
        if !account.hasSession { await account.ensureSession() }
        guard account.hasSession else { problem = L("shop.noServer"); return }
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
        if Self.subscriptions.contains(transaction.productID) {
            await activate(transaction, jws: result.jwsRepresentation)
            return
        }
        guard Self.credits(of: transaction.productID) != nil else { return }
        if !account.hasSession { await account.ensureSession() }
        guard account.hasSession else {
            problem = L("shop.notCredited", L("shop.noServer"))
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

    /// Called from the subscription store view when a purchase completes.
    func subscriptionPurchased(_ result: VerificationResult<Transaction>) async {
        problem = nil
        message = nil
        await handle(result)
    }

    /// Sends the membership's current entitlement (if this Apple ID has one)
    /// to the server: on launch, on every return to the foreground and after
    /// signing in. Quiet: a failure just waits for the next time.
    func syncSubscription() async {
        guard account.hasSession, !account.isDemo, !syncing else { return }
        syncing = true
        defer { syncing = false }
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result,
                  Self.subscriptions.contains(transaction.productID) else { continue }
            try? await sendSubscription(transaction, jws: result.jwsRepresentation)
        }
    }

    private var syncing = false

    /// A subscription transaction (new purchase, renewal, upgrade): the
    /// server records it, then it is finished. Left unfinished on failure.
    private func activate(_ transaction: Transaction, jws: String) async {
        if !account.hasSession { await account.ensureSession() }
        guard account.hasSession else {
            problem = L("member.notActivated", L("shop.noServer"))
            return
        }
        do {
            try await sendSubscription(transaction, jws: jws)
            await transaction.finish()
            if account.membership?.active == true, transaction.revocationDate == nil,
               Date().timeIntervalSince(transaction.purchaseDate) < 600 {
                message = L("member.welcome")
            }
        } catch {
            problem = L("member.notActivated", error.localizedDescription)
        }
    }

    /// POST /subscription with the transaction and, when StoreKit has it,
    /// its renewal info (auto-renew on/off, billing grace period).
    private func sendSubscription(_ transaction: Transaction, jws: String) async throws {
        var body = ["jws": jws]
        if let renewal = await renewalInfo(for: transaction) { body["renewalJws"] = renewal }
        let request = Backend.request("subscription", method: "POST", token: account.sessionToken, json: body)
        let reply = try await Backend.send(request)
        account.applyMembership(reply["subscription"])
        if let total = reply["totalCredits"] as? NSNumber { account.applyBalance(total.intValue) }
    }

    /// The signed renewal info of the subscription `transaction` belongs to.
    private func renewalInfo(for transaction: Transaction) async -> String? {
        guard let product = try? await Product.products(for: [transaction.productID]).first,
              let statuses = try? await product.subscription?.status
        else { return nil }
        return statuses.first { status in
            guard case let .verified(current) = status.transaction else { return false }
            return current.originalID == transaction.originalID
        }?.renewalInfo.jwsRepresentation
    }

    /// Credits the pack adds, nil for a product that isn't ours.
    static func credits(of id: String) -> Int? {
        packs.first { $0.id == id }?.credits
    }
}
