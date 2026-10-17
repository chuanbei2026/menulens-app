import Foundation

/// The signed-in account: the session token (Keychain) and the credit
/// balance the server last reported. Scanning needs a session; the bundled
/// samples and saved history work without one.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var sessionToken = KeychainStore.loadSessionToken()
    /// Whole credits; nil until the server has answered once.
    @Published private(set) var credits: Int?
    /// The last 30 days, oldest first (the server's billing time zone).
    @Published private(set) var usage: [UsageDay] = []
    /// The subscription as the server last reported it; nil until it has
    /// answered (and for accounts that never subscribed, inactive).
    @Published private(set) var membership: Membership?
    /// Why the user is signed out, or what last went wrong with the account.
    @Published var message: String?
    @Published private(set) var isBusy = false

    var isSignedIn: Bool { !sessionToken.isEmpty }

    private init() {
        KeychainStore.removeLegacyAPIKey()
    }

    /// Exchanges a Sign in with Apple identity token for our session token.
    /// The first sign-in creates the account with its starting credits. The
    /// authorization code, when Apple gives one, lets the server revoke the
    /// authorization when the account is deleted.
    func signIn(identityToken: String, authorizationCode: String? = nil) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let request = Backend.request(
                "auth/apple", method: "POST", token: "",
                json: ["identityToken": identityToken, "authorizationCode": authorizationCode]
                    .compactMapValues { $0 }
            )
            // A 401 here is Apple's token being rejected, not an expired
            // session — report it as a failed sign-in.
            let reply = try await Backend.send(request, signsOutOn401: false)
            guard let token = reply["token"] as? String, !token.isEmpty else {
                throw Backend.BackendError.http(200, "no token")
            }
            setSession(token)
            await refreshCredits()
        } catch {
            message = L("error.signInFailed", error.localizedDescription)
        }
    }

    func setSession(_ token: String) {
        KeychainStore.saveSessionToken(token)
        sessionToken = token
        credits = nil
        message = nil
        membership = nil
        cachedPurchaseToken = nil
        // Purchases paid for while signed out (or before a crash) can be
        // credited now, and a subscription bought on this Apple ID linked.
        CreditShop.shared.retryUnfinished()
        Task { await CreditShop.shared.syncSubscription() }
    }

    #if DEBUG
    /// Unit tests can't pass launch arguments to the host app: this is their
    /// `-demoUsage`.
    static var forceDemo = false
    #endif

    /// `true` while DEBUG screenshots run on made-up account data: nothing
    /// account-related is sent to the server.
    var isDemo: Bool {
        #if DEBUG
        return Self.forceDemo || ProcessInfo.processInfo.arguments.contains("-demoUsage")
        #else
        return false
        #endif
    }

    /// One day of the credit history: what was used and added, and the
    /// balance at the end of the day (all whole credits).
    struct UsageDay: Identifiable, Equatable {
        let date: Date
        let spent: Int
        let added: Int
        let balance: Int
        var id: Date { date }
    }

    /// The balance and the 30-day history in one call (`GET /usage`).
    func refreshCredits() async {
        guard isSignedIn else { return }
        #if DEBUG
        // `-demoUsage`: a plausible month instead of the dev account's own
        // (App Store screenshots of Settings → Account).
        if isDemo {
            applyDemoUsage()
            return
        }
        #endif
        let request = Backend.request("usage", token: sessionToken)
        guard let reply = try? await Backend.send(request),
              let balance = reply["balance"] as? [String: Any],
              let total = balance["totalCredits"] as? NSNumber
        else { return }
        credits = total.intValue
        applyMembership(reply["subscription"])
        let days = reply["days"] as? [[String: Any]] ?? []
        usage = days.compactMap { day in
            guard let key = day["date"] as? String, let date = Self.dayFormatter.date(from: key) else { return nil }
            func whole(_ field: String) -> Int { (day[field] as? NSNumber)?.intValue ?? 0 }
            return UsageDay(date: date, spent: whole("spent"), added: whole("added"), balance: whole("balance"))
        }
    }

    /// The UUID every StoreKit purchase carries (`appAccountToken` from
    /// GET /credits): the server credits a transaction only to the account
    /// whose token it carries. Fixed per account, so fetched once.
    func purchaseToken() async -> UUID? {
        if let cachedPurchaseToken { return cachedPurchaseToken }
        #if DEBUG
        if isDemo { return UUID(uuidString: "00000000-0000-4000-A000-000000000000") }
        #endif
        guard isSignedIn,
              let reply = try? await Backend.send(Backend.request("credits", token: sessionToken)),
              let text = reply["appAccountToken"] as? String,
              let token = UUID(uuidString: text)
        else { return nil }
        cachedPurchaseToken = token
        return token
    }

    private var cachedPurchaseToken: UUID?

    /// The balance a purchase reply reported, ahead of the next refresh.
    func applyBalance(_ total: Int) {
        credits = total
    }

    /// The `subscription` object of GET /usage, /credits or POST /subscription.
    func applyMembership(_ json: Any?) {
        if let membership = Membership(json: json) { self.membership = membership }
    }

    /// Redeems a promotion code (POST /promo/redeem). The server ignores
    /// case and spaces. Returns what to tell the user; on success the
    /// balance and chart are refreshed.
    func redeem(_ code: String) async -> (ok: Bool, message: String) {
        let request = Backend.request(
            "promo/redeem", method: "POST", token: sessionToken,
            json: ["code": code.trimmingCharacters(in: .whitespacesAndNewlines)]
        )
        do {
            let reply = try await Backend.send(request)
            let credits = (reply["credits"] as? NSNumber)?.intValue ?? 0
            if let total = reply["totalCredits"] as? NSNumber { applyBalance(total.intValue) }
            await refreshCredits()
            return (true, L("redeem.success", reply["code"] as? String ?? code, credits))
        } catch let Backend.BackendError.http(_, reason)
            where ["not_found", "inactive", "expired", "used_up", "already_redeemed"].contains(reason) {
            // The promo errors carry their reason as the message.
            return (false, L("redeem.error.\(reason)"))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    #if DEBUG
    /// 30 days ending today: small daily use with idle days, one 500-credit
    /// purchase mid-month; 6 used today, 95 in the 30 days, ending at 640.
    private func applyDemoUsage() {
        let spends = [0, 4, 7, 0, 0, 9, 3, 0, 5, 0, 2, 8, 0, 0, 11, 4, 0, 0, 6, 3, 0, 7, 4, 2, 0, 5, 6, 3, 0, 6]
        let purchaseDay = 15
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var balance = 640 - 500 + spends.reduce(0, +)
        usage = spends.enumerated().map { index, spent in
            let added = index == purchaseDay ? 500 : 0
            balance += added - spent
            let date = calendar.date(byAdding: .day, value: index - (spends.count - 1), to: today)!
            return UsageDay(date: date, spent: spent, added: added, balance: balance)
        }
        credits = balance
        // `-demoMembership` (a member this month, 87 of 600 used) or
        // `-demoMembershipOver` (past the fair use): the membership card.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demoMembership") || args.contains("-demoMembershipOver") {
            membership = Membership(
                active: true, productID: CreditShop.subscriptions[2],
                expiresAt: calendar.date(byAdding: .month, value: 11, to: today), autoRenew: true,
                monthUsedCredits: args.contains("-demoMembershipOver") ? 612 : 87, monthFairUseCredits: 600
            )
        }
    }
    #endif

    /// "2026-10-15" → local midnight, for the chart's day axis.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func signOut() {
        KeychainStore.saveSessionToken("")
        sessionToken = ""
        credits = nil
        usage = []
        membership = nil
        cachedPurchaseToken = nil
    }

    /// The server no longer accepts the session (it expires after 30 days).
    func sessionDidExpire() {
        guard isSignedIn else { return }
        signOut()
        message = L("error.sessionExpired")
    }

    /// Deletes the account and its credits on the server (App Store
    /// guideline 5.1.1(v)), then signs out. History stays on the phone.
    func deleteAccount() async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await Backend.send(Backend.request("account", method: "DELETE", token: sessionToken))
            signOut()
        } catch {
            message = error.localizedDescription
        }
    }
}
