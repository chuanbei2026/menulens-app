import StoreKit
import SwiftUI

/// The membership (StoreKit's subscription store) above three credit packs.
/// Prices come from the App Store (local currency); names are ours, so they
/// follow the app language.
struct ShopView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var shop = CreditShop.shared
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var loc = Localization.shared
    @State private var purchaseToken: UUID?
    @State private var showManage = false
    @State private var showOfferCode = false

    /// Apple's standard license agreement (the app has no EULA of its own).
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(L("settings.account.balance")) {
                        Text(account.credits.map { L("settings.account.credits", $0) } ?? "—")
                            .font(.headline.monospacedDigit())
                    }
                }
                membershipSection
                Section {
                    if shop.loading, shop.products.isEmpty {
                        HStack {
                            ProgressView()
                            Text(L("shop.loading")).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(shop.products, id: \.id) { product in
                        PackRow(product: product, buying: shop.buying == product.id) {
                            Task { await shop.buy(product) }
                        }
                        .disabled(shop.buying != nil)
                    }
                } header: {
                    Text(L("shop.header"))
                } footer: {
                    Text(L("shop.footer"))
                }
                // Apple's own redemption sheet for App Store Offer Codes. The
                // redeemed pack comes in through Transaction.updates
                // (CreditShop), like any purchase.
                Section {
                    Button {
                        showOfferCode = true
                    } label: {
                        Label(L("shop.offerCode"), systemImage: "giftcard")
                    }
                }
                if let message = shop.message {
                    Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if let problem = shop.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .navigationTitle(L("shop.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
                }
            }
            .task {
                shop.message = nil
                shop.problem = nil
                await account.ensureSession()
                await shop.loadProducts()
                await account.refreshCredits()
                purchaseToken = await account.purchaseToken()
            }
            .manageSubscriptionsSheet(isPresented: $showManage)
            .offerCodeRedemption(isPresented: $showOfferCode) { _ in
                Task { await account.refreshCredits() }
            }
        }
    }

    /// What the membership gives, the plans (StoreKit draws them, with
    /// prices and periods from the App Store), terms and privacy links.
    /// Buying needs the account's purchase token, so without a session (not
    /// reached the server yet) the pitch shows alone; so do regions (or
    /// builds) where StoreKit has no plans.
    private var membershipSection: some View {
        Section {
            if let membership = account.membership, membership.active {
                MembershipStatus(membership: membership)
                Button(L("member.manage")) { showManage = true }
            }
            if account.hasSession, !shop.plans.isEmpty {
                SubscriptionStoreView(productIDs: CreditShop.subscriptions) {
                    MembershipPitch()
                }
                .subscriptionStoreControlStyle(.buttons)
                .subscriptionStoreButtonLabel(.multiline)
                .storeButton(.visible, for: .restorePurchases)
                .storeButton(.visible, for: .policies)
                .storeButton(.hidden, for: .cancellation)
                .subscriptionStorePolicyDestination(url: Self.termsOfUse, for: .termsOfService)
                .subscriptionStorePolicyDestination(url: AIConsentView.privacyPolicy, for: .privacyPolicy)
                .inAppPurchaseOptions { _ in
                    purchaseToken.map { [.appAccountToken($0)] } ?? []
                }
                .onInAppPurchaseCompletion { _, result in
                    if case let .success(.success(transaction)) = result {
                        await shop.subscriptionPurchased(transaction)
                    }
                }
                .environment(\.locale, loc.locale)
                .frame(height: 560)
                .listRowInsets(EdgeInsets())
            } else {
                MembershipPitch()
                if !account.hasSession {
                    Text(L("shop.noServer")).foregroundStyle(.secondary)
                } else if !shop.loading {
                    Text(L("member.unavailable")).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L("member.header"))
        } footer: {
            Text(L("member.footer"))
        }
    }
}

/// The membership's promise, above the plans.
struct MembershipPitch: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("member.pitch.title"), systemImage: "crown.fill")
                .font(.title3.bold())
                .foregroundStyle(.orange)
            point("infinity", L("member.pitch.unlimited"))
            point("gauge.with.needle", L("member.pitch.fairUse", CreditShop.fairUseCredits))
            point("gift", L("member.pitch.grant", CreditShop.monthlyGrantCredits))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func point(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).foregroundStyle(.orange)
        }
        .font(.subheadline)
    }
}

/// 「会员 · 到 …」 and whether it renews.
struct MembershipStatus: View {
    let membership: Membership

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MembershipBadge(membership: membership)
            if let autoRenew = membership.autoRenew {
                Text(L(autoRenew ? "member.autoRenew.on" : "member.autoRenew.off"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The capsule: crown, 「会员 · 到 2027年9月17日」.
struct MembershipBadge: View {
    let membership: Membership

    var body: some View {
        Label(text, systemImage: "crown.fill")
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
            .foregroundStyle(.orange)
    }

    private var text: String {
        guard let date = membership.expiresAt else { return L("member.header") }
        let day = date.formatted(.dateTime.year().month(.abbreviated).day().locale(Localization.shared.locale))
        return L("member.badge", day)
    }
}

private struct PackRow: View {
    let product: Product
    let buying: Bool
    let buy: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "seal.fill")
                .font(.title2)
                .foregroundStyle(.orange.gradient)
            Text(L("settings.account.credits", CreditShop.credits(of: product.id) ?? 0))
                .font(.title3.bold().monospacedDigit())
            Spacer()
            Button(action: buy) {
                if buying { ProgressView() } else { Text(product.displayPrice).monospacedDigit() }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
        .padding(.vertical, 4)
    }
}
