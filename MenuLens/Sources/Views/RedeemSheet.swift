import SwiftUI

/// Settings → Account → Redeem code: one field, one button, and what the
/// server said about the code.
struct RedeemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var loc = Localization.shared
    @State private var code = ""
    @State private var working = false
    @State private var result: (ok: Bool, message: String)?

    #if DEBUG
    /// `-redeem <code>` (with -showSettings): fill the field and submit, for
    /// headless checks of the sheet against the live server.
    private static var automationCode: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-redeem"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    #endif

    private var canRedeem: Bool {
        !working && result?.ok != true && !code.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("redeem.placeholder"), text: $code)
                        .font(.title3.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { if canRedeem { Task { await redeem() } } }
                        .onChange(of: code) { if result?.ok == false { result = nil } }
                } footer: {
                    Text(L("redeem.footer"))
                }
                if let result {
                    Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.ok ? .green : .orange)
                }
            }
            .navigationTitle(L("redeem.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L(result?.ok == true ? "common.done" : "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button(L("redeem.action")) { Task { await redeem() } }
                            .disabled(!canRedeem)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        #if DEBUG
        .task {
            guard let automated = Self.automationCode, code.isEmpty else { return }
            code = automated
            await redeem()
        }
        #endif
    }

    private func redeem() async {
        working = true
        result = await account.redeem(code)
        working = false
    }
}
