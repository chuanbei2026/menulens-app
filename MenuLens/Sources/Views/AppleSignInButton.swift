import AuthenticationServices
import SwiftUI

/// Sign in with Apple, exchanged for our own session at once. No scopes are
/// requested: the server needs a stable account id, not a name or email.
struct AppleSignInButton: View {
    @ObservedObject private var account = AccountStore.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = []
        } onCompletion: { result in
            switch result {
            case let .success(authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let data = credential.identityToken,
                      let identityToken = String(data: data, encoding: .utf8)
                else {
                    account.message = L("error.signInFailed", L("common.unknown"))
                    return
                }
                Task { await account.signIn(identityToken: identityToken) }
            case let .failure(error):
                // Closing the Apple sheet is a choice, not an error.
                if (error as? ASAuthorizationError)?.code == .canceled { return }
                account.message = L("error.signInFailed", error.localizedDescription)
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 44)
        .disabled(account.isBusy)
        .opacity(account.isBusy ? 0.5 : 1)
    }
}
