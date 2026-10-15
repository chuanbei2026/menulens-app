import Charts
import SwiftUI

/// Settings → Account: the balance, what was used today and in the last 30
/// days, and a chart of either the balance or the daily use.
struct CreditsCard: View {
    @ObservedObject var account: AccountStore
    /// Opens the shop; the card has no sheet of its own.
    var onBuy: (() -> Void)?
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
            if let onBuy {
                Button(action: onBuy) {
                    Label(L("shop.buy"), systemImage: "cart.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
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
