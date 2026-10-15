import Foundation

/// Our own server (backend/README.md). It signs users in with Apple, keeps
/// their credit balance and relays menu and image requests to OpenAI with
/// our key — so the app never needs the user's own OpenAI key.
enum Backend {
    static let baseURL = URL(string: "https://uwondrk7ngmf3jgkimsifwa62q0fwgzo.lambda-url.us-west-2.on.aws")!

    enum BackendError: LocalizedError {
        /// No session token on this phone yet.
        case signInRequired
        /// The server rejected the session token (401): sign in again.
        case sessionExpired
        /// 402: the request costs more than the balance.
        case outOfCredits(balance: Int, needed: Int)
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .signInRequired:
                return L("error.signInRequired")
            case .sessionExpired:
                return L("error.sessionExpired")
            case let .outOfCredits(balance, needed):
                return L("error.outOfCredits", needed, balance)
            case let .http(code, message):
                return L("error.http", code, message)
            }
        }
    }

    static func request(_ path: String, method: String = "GET", token: String, json: Any? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    /// Turns a non-2xx answer into an error. Errors look like
    /// `{error: {message, …}}`; a 402 also carries the balance and what the
    /// request needed. A 401 on a signed-in request means the session is
    /// gone, so the app drops to the signed-out state right away.
    static func failure(status: Int, body: Data, signsOutOn401: Bool = true) -> BackendError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let detail = object?["error"] as? [String: Any]
        func whole(_ key: String) -> Int {
            let number = (object?[key] ?? detail?[key]) as? NSNumber
            return Int((number?.doubleValue ?? 0).rounded(.up))
        }
        switch status {
        case 401 where signsOutOn401:
            Task { @MainActor in AccountStore.shared.sessionDidExpire() }
            return .sessionExpired
        case 402:
            return .outOfCredits(balance: whole("totalCredits"), needed: whole("needed"))
        default:
            let message = detail?["message"] as? String
                ?? String(decoding: body.prefix(500), as: UTF8.self)
            return .http(status, message)
        }
    }

    /// One JSON round trip for the small account endpoints.
    static func send(_ request: URLRequest, signsOutOn401: Bool = true) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw failure(status: status, body: data, signsOutOn401: signsOutOn401)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
