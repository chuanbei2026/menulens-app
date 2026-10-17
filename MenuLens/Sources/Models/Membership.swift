import Foundation

/// The account's subscription (ForeignMenu Membership) as the server reports
/// it in `subscription` (backend/src/subscription.mjs): while active, scans
/// and dish pictures don't use credits up to a monthly fair use, and the
/// account gets a few credits every month.
struct Membership: Equatable {
    var active: Bool
    var productID: String?
    /// When access ends (the end of a billing grace period, if in one).
    var expiresAt: Date?
    /// nil until the server has seen renewal info.
    var autoRenew: Bool?
    /// Covered so far this billing month, and the fair use (whole credits).
    var monthUsedCredits: Int
    var monthFairUseCredits: Int

    /// Past this month's fair use: calls are charged from the balance again.
    var overFairUse: Bool { active && monthUsedCredits >= monthFairUseCredits }

    init(active: Bool, productID: String?, expiresAt: Date?, autoRenew: Bool?,
         monthUsedCredits: Int, monthFairUseCredits: Int) {
        self.active = active
        self.productID = productID
        self.expiresAt = expiresAt
        self.autoRenew = autoRenew
        self.monthUsedCredits = monthUsedCredits
        self.monthFairUseCredits = monthFairUseCredits
    }

    /// From the server's JSON; nil when the reply has no `subscription`
    /// (a server from before subscriptions).
    init?(json: Any?) {
        guard let object = json as? [String: Any], let active = object["active"] as? Bool else { return nil }
        func whole(_ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }
        self.init(
            active: active,
            productID: object["productId"] as? String,
            expiresAt: (object["expiresAt"] as? String).flatMap(Self.parseDate),
            autoRenew: object["autoRenew"] as? Bool,
            monthUsedCredits: whole("monthUsedCredits") ?? 0,
            monthFairUseCredits: whole("monthFairUseCredits") ?? CreditShop.fairUseCredits
        )
    }

    /// ISO 8601 with or without fractional seconds (JavaScript writes them).
    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
