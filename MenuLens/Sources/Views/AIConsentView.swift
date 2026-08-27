import SwiftUI

/// Consent for sending a menu photo to OpenAI, shown before the FIRST such
/// send and never again once granted.
///
/// Required by App Store Review Guideline 5.1.2(i), which since November
/// 2025 names third-party AI explicitly: personal data may not be shared
/// with it without disclosing where it goes and obtaining permission first.
/// A photo is personal data, so scanning cannot precede this sheet.
///
/// Three things the guideline (and the reviewer) look for, all here:
///   1. the provider is named — OpenAI, not "our AI partner";
///   2. the data categories are listed, and so is what stays on the device;
///   3. declining is real. "Not now" leaves the app fully usable: the
///      bundled sample menus and every saved translation are local.
///
/// Revocable from Settings — the fourth thing the guideline asks for.
struct AIConsentView: View {
    let onAgree: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var loc = Localization.shared

    /// Kept in step with the privacy policy and the App Privacy answers in
    /// App Store Connect; review cross-checks all three against what the
    /// binary actually sends.
    static let privacyPolicy = URL(
        string: "https://chuanbei2026.github.io/menulens-app/privacy-policy.html"
    )!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "arrow.up.doc.on.clipboard")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text(L("consent.title"))
                            .font(.title3.weight(.semibold))
                        Text(L("consent.body"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    group(
                        icon: "paperplane.fill",
                        tint: .orange,
                        title: L("consent.sent.header"),
                        rows: [L("consent.sent.photo"), L("consent.sent.names")]
                    )

                    group(
                        icon: "lock.fill",
                        tint: .green,
                        title: L("consent.kept.header"),
                        rows: [L("consent.kept.body")]
                    )

                    Text(L("consent.retention"))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)

                    Link(destination: Self.privacyPolicy) {
                        Label(L("consent.policy"), systemImage: "hand.raised")
                            .font(.footnote)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        onAgree()
                        dismiss()
                    } label: {
                        Text(L("consent.agree"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(L("consent.decline")) { dismiss() }
                        .font(.subheadline)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(.thinMaterial)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func group(icon: String, tint: Color, title: String, rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            ForEach(rows, id: \.self) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").font(.footnote).foregroundStyle(.tertiary)
                    Text(row).font(.footnote)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
