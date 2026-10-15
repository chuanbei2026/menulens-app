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
    /// Why the user is signed out, or what last went wrong with the account.
    @Published var message: String?
    @Published private(set) var isBusy = false

    var isSignedIn: Bool { !sessionToken.isEmpty }

    private init() {
        KeychainStore.removeLegacyAPIKey()
    }

    /// Exchanges a Sign in with Apple identity token for our session token.
    /// The first sign-in creates the account with its starting credits.
    func signIn(identityToken: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let request = Backend.request(
                "auth/apple", method: "POST", token: "",
                json: ["identityToken": identityToken]
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
        cachedPurchaseToken = nil
        // Purchases paid for while signed out (or before a crash) can be
        // credited now.
        CreditShop.shared.retryUnfinished()
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
        let request = Backend.request("usage", token: sessionToken)
        guard let reply = try? await Backend.send(request),
              let balance = reply["balance"] as? [String: Any],
              let total = balance["totalCredits"] as? NSNumber
        else { return }
        credits = total.intValue
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
