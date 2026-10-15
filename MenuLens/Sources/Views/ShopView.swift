import StoreKit
import SwiftUI

/// Three credit packs, each with 10% extra. Prices come from the App Store
/// (local currency); names are ours, so they follow the app language.
struct ShopView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var shop = CreditShop.shared
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var loc = Localization.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(L("settings.account.balance")) {
                        Text(account.credits.map { L("settings.account.credits", $0) } ?? "—")
                            .font(.headline.monospacedDigit())
                    }
                }
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
                await shop.loadProducts()
                await account.refreshCredits()
            }
        }
    }
}

private struct PackRow: View {
    let product: Product
    let buying: Bool
    let buy: () -> Void

    var body: some View {
        let pack = CreditShop.pack(product.id)
        HStack(spacing: 12) {
            Image(systemName: "seal.fill")
                .font(.title2)
                .foregroundStyle(.orange.gradient)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("settings.account.credits", pack.map { $0.credits + $0.bonus } ?? 0))
                    .font(.title3.bold().monospacedDigit())
                if let pack {
                    Text(L("shop.pack.detail", pack.credits, pack.bonus))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
