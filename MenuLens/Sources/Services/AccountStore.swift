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
    }

    func refreshCredits() async {
        guard isSignedIn else { return }
        let request = Backend.request("credits", token: sessionToken)
        guard let reply = try? await Backend.send(request),
              let total = reply["totalCredits"] as? NSNumber
        else { return }
        credits = total.intValue
    }

    func signOut() {
        KeychainStore.saveSessionToken("")
        sessionToken = ""
        credits = nil
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
