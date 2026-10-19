import Foundation

/// The account: the session token (Keychain) and the credit balance the
/// server last reported.
///
/// Nobody has to sign in (App Review 5.1.1(v)). On first launch the app opens
/// an anonymous **device account** (POST /auth/anonymous: 300 free credits)
/// and keeps its credentials in the Keychain, so scanning, the shop, purchases
/// and the membership all work at once, and reinstalling finds the same
/// account. Sign in with Apple is optional: it moves the device account into
/// the Apple account (POST /auth/apple/link), whose balance then follows the
/// Apple ID to other devices. Signing out of Apple returns to the device's own
/// account — a new, empty one, since its balance went to the Apple account
/// (the server never gives a device the signup credits twice).
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

    /// What happened that the user should know (the balance moved over).
    @Published var notice: String?

    /// Whether there is a session at all (device or Apple account).
    var hasSession: Bool { !sessionToken.isEmpty }
    /// Signed in with Apple, rather than on the device account. Read from the
    /// session's own claims ("apple:<sub>" / "anon:<uuid>").
    var isAppleAccount: Bool { Self.claims(of: sessionToken)?.sub.hasPrefix("apple:") == true }

    private init() {
        KeychainStore.removeLegacyAPIKey()
        #if DEBUG
        // Keychain items outlive an app uninstall, so a first launch needs an
        // explicit way to reproduce — before anything opens a session.
        if ProcessInfo.processInfo.arguments.contains("-signOut") { forgetEverything() }
        #endif
    }

    /// Sign in with Apple. From the device account the server moves it into
    /// the Apple account (a new Apple ID gets it as is, no second 300; an
    /// existing one has the balance added) and answers with the Apple
    /// account's session. The authorization code, when Apple gives one, lets
    /// the server revoke the authorization when the account is deleted.
    func signIn(identityToken: String, authorizationCode: String? = nil) async {
        isBusy = true
        defer { isBusy = false }
        let body = ["identityToken": identityToken, "authorizationCode": authorizationCode].compactMapValues { $0 }
        do {
            var reply: [String: Any]
            if hasSession, !isAppleAccount {
                do {
                    reply = try await Backend.send(Backend.request("auth/apple/link", method: "POST", token: sessionToken, json: body),
                                                   signsOutOn401: false)
                } catch Backend.BackendError.http(401, _) where !isDemo {
                    // The device session lapsed: renew it and link once more.
                    await openDeviceSession()
                    reply = try await Backend.send(Backend.request("auth/apple/link", method: "POST", token: sessionToken, json: body),
                                                   signsOutOn401: false)
                }
            } else {
                // A 401 here is Apple's token being rejected, not an expired
                // session — report it as a failed sign-in.
                reply = try await Backend.send(Backend.request("auth/apple", method: "POST", token: "", json: body), signsOutOn401: false)
            }
            guard let token = reply["token"] as? String, !token.isEmpty else {
                throw Backend.BackendError.http(200, "no token")
            }
            setSession(token)
            if let moved = (reply["movedCredits"] as? NSNumber)?.intValue, moved > 0 {
                notice = L("settings.account.linked", moved)
            }
            await refreshCredits()
        } catch {
            message = L("error.signInFailed", error.localizedDescription)
        }
    }

    /// Makes sure there is a session: the stored one (renewed when it is a
    /// week old), else the device account's. Launch, every scan and every
    /// rejected session go through here; concurrent callers share one run.
    func ensureSession() async {
        if let renewal { return await renewal.value }
        let run = Task { await establishSession() }
        renewal = run
        await run.value
        renewal = nil
    }

    private var renewal: Task<Void, Never>?

    private func establishSession() async {
        if isDemo { return }
        if let claims = Self.claims(of: sessionToken) {
            let now = Date().timeIntervalSince1970
            if claims.exp > now + 23 * 86400 { return } // under a week old
            if claims.exp > now + 60, let reply = try? await Backend.send(Backend.request("auth/refresh", method: "POST", token: sessionToken),
                                                                       signsOutOn401: false),
               let token = reply["token"] as? String, !token.isEmpty {
                KeychainStore.saveSessionToken(token)
                sessionToken = token
                return
            }
            if claims.exp > now { return } // offline: keep it, the server decides
            if isAppleAccount { message = L("error.sessionExpired") }
        }
        await openDeviceSession()
    }

    /// POST /auth/anonymous with the device account's credentials (none on
    /// first launch): the session for this device's own account. The server
    /// answers with new credentials when it opened a new account.
    private func openDeviceSession() async {
        let device = KeychainStore.loadDeviceAccount()
        let body = device.map { ["deviceId": $0.id, "deviceSecret": $0.secret] } ?? [:]
        do {
            var reply: [String: Any]
            do {
                reply = try await Backend.send(Backend.request("auth/anonymous", method: "POST", token: "", json: body), signsOutOn401: false)
            } catch Backend.BackendError.http(401, _) where device != nil {
                // Credentials the server doesn't know (a Keychain restored
                // from another app install): start afresh.
                reply = try await Backend.send(Backend.request("auth/anonymous", method: "POST", token: "", json: [String: String]()),
                                               signsOutOn401: false)
            }
            guard let token = reply["token"] as? String, !token.isEmpty else {
                throw Backend.BackendError.http(200, "no token")
            }
            if let id = reply["deviceId"] as? String, let secret = reply["deviceSecret"] as? String {
                KeychainStore.saveDeviceAccount(id: id, secret: secret)
            }
            setSession(token, keepMessage: true)
        } catch {
            // Quiet: the next scan (or launch) tries again and says why if
            // it still can't (error.signInRequired).
        }
    }

    /// The claims of one of our session tokens (an HS256 JWT): who and until when.
    static func claims(of token: String) -> (sub: String, exp: TimeInterval)? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sub = json["sub"] as? String
        else { return nil }
        return (sub, (json["exp"] as? NSNumber)?.doubleValue ?? 0)
    }

    func setSession(_ token: String, keepMessage: Bool = false) {
        KeychainStore.saveSessionToken(token)
        sessionToken = token
        credits = nil
        if !keepMessage { message = nil }
        notice = nil
        membership = nil
        cachedPurchaseToken = nil
        // Purchases paid for before there was a session (or before a crash)
        // can be credited now, and a subscription bought on this Apple ID linked.
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
        guard hasSession else { return }
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
        guard hasSession,
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

    /// Forgets the session on this device.
    private func dropSession() {
        KeychainStore.saveSessionToken("")
        sessionToken = ""
        credits = nil
        usage = []
        membership = nil
        cachedPurchaseToken = nil
    }

    /// Signs out of Apple: the balance stays with the Apple account, and this
    /// device goes back to its own account (a new, empty one — see the type).
    func signOut() async {
        dropSession()
        notice = nil
        message = nil
        await ensureSession()
        await refreshCredits()
    }

    #if DEBUG
    /// `-freshInstall`: as a brand-new install, before the first session.
    func forgetEverything() {
        dropSession()
        KeychainStore.forgetDeviceAccount()
    }
    #endif

    /// The server no longer accepts the session (401). A device session is
    /// renewed silently with the device secret; an Apple session that lapsed
    /// (30 days unused) falls back to the device's account and says to sign
    /// in again; "merged" means this device account moved into an Apple
    /// account (a link whose answer never arrived).
    func sessionDidExpire(reason: String? = nil) {
        guard hasSession, renewal == nil, !isDemo else { return }
        let wasApple = isAppleAccount
        dropSession()
        message = reason == "merged" ? L("account.merged") : wasApple ? L("error.sessionExpired") : nil
        Task {
            await ensureSession()
            await refreshCredits()
        }
    }

    /// Deletes the account and its credits on the server (App Store
    /// guideline 5.1.1(v)) — the device account or the Apple account,
    /// whichever this is. The device then continues on a new, empty device
    /// account. History stays on the phone.
    func deleteAccount() async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await Backend.send(Backend.request("account", method: "DELETE", token: sessionToken))
            await signOut()
        } catch {
            message = error.localizedDescription
        }
    }
}
