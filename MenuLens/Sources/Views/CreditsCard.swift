import Charts
import SwiftUI

/// Settings → Account: the balance, what was used today and in the last 30
/// days, and a chart of either the balance or the daily use.
struct CreditsCard: View {
    @ObservedObject var account: AccountStore
    /// Open the shop / the redeem-code sheet; the card has no sheets of its own.
    var onBuy: (() -> Void)?
    var onRedeem: (() -> Void)?
    @State private var mode = Mode.balance

    enum Mode: CaseIterable, Identifiable {
        case balance, spent
        var id: Self { self }
        var label: String { L(self == .balance ? "credits.chart.balance" : "credits.chart.spent") }
    }

    private var days: [AccountStore.UsageDay] { account.usage }
    private var today: Int { days.last?.spent ?? 0 }
    private var last30: Int { days.reduce(0) { $0 + $1.spent } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("settings.account.balance")).font(.caption).foregroundStyle(.secondary)
                    if let credits = account.credits {
                        Text(L("settings.account.credits", credits))
                            .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    } else {
                        ProgressView()
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    stat(L("credits.today"), today)
                    stat(L("credits.last30"), last30)
                }
            }
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            chart.frame(height: 120)
            // Side by side when both labels fit; stacked otherwise ("Acheter
            // des crédits" / "Utiliser un code" don't, on a phone).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actionButtons }
                VStack(spacing: 8) { actionButtons }
            }
            // Bordered buttons keep their own hit areas inside the Form row.
            .buttonStyle(.bordered)
        }
    }

    /// Icon + text spelled out rather than a Label: inside ViewThatFits a
    /// Label measured at its ideal size dropped to icon-only.
    @ViewBuilder private var actionButtons: some View {
        if let onBuy {
            Button(action: onBuy) { buttonLabel(L("shop.buy"), icon: "cart.badge.plus") }
        }
        if let onRedeem {
            Button(action: onRedeem) { buttonLabel(L("redeem.button"), icon: "ticket") }
        }
    }

    private func buttonLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title).lineLimit(1)
        }
        .fixedSize()
        .frame(maxWidth: .infinity)
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(L("settings.account.credits", value)).monospacedDigit()
        }
        .font(.caption)
    }

    @ViewBuilder private var chart: some View {
        if days.isEmpty {
            Text(L("credits.chart.empty"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(days) { day in
                switch mode {
                case .balance:
                    AreaMark(x: .value("day", day.date, unit: .day), y: .value("balance", day.balance))
                        .foregroundStyle(.linearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.stepEnd)
                    LineMark(x: .value("day", day.date, unit: .day), y: .value("balance", day.balance))
                        .foregroundStyle(Color.accentColor)
                        .interpolationMethod(.stepEnd)
                case .spent:
                    BarMark(x: .value("day", day.date, unit: .day), y: .value("spent", day.spent))
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(2)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                }
            }
            .chartYAxis { AxisMarks(position: .trailing) }
            // The day labels follow the app's language, not the phone's.
            .environment(\.locale, Locale(identifier: Localization.shared.language.rawValue))
        }
    }
}
