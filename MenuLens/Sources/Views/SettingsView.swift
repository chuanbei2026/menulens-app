import PhotosUI
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(RegionStore.modelKey) private var model = "gpt-4.1"
    @AppStorage("thumbnail_grid_mode") private var thumbnailGridMode = true
    @AppStorage("flatten_lighting") private var flattenLighting = true
    @AppStorage(AIConsentView.grantedKey) private var aiConsentGranted = false
    /// The language picker writes through `Localization`, so every screen in
    /// the app follows the choice immediately — see Localization.swift.
    @ObservedObject private var loc = Localization.shared
    @ObservedObject private var party = PartyStore.shared
    @ObservedObject private var account = AccountStore.shared
    @State private var confirmDelete = false
    @State private var confirmSignOut = false
    @State private var showShop = false
    /// The optional "sign in to use your balance on other devices" hint,
    /// once closed, stays closed (the Apple button itself stays).
    @AppStorage("hint.appleSignIn.dismissed") private var appleHintDismissed = false
    @State private var newMemberName = ""
    @State private var avatarTargetID: UUID?
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var showAvatarPicker = false

    /// The models this App Store region offers (GET /models).
    @ObservedObject private var region = RegionStore.shared

    private func addMember() {
        party.add(name: newMemberName)
        newMemberName = ""
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection

                Section {
                    Picker(
                        L("settings.language"),
                        selection: Binding(
                            get: { loc.language },
                            set: { loc.setLanguage($0) }
                        )
                    ) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                } footer: {
                    Text(L("settings.language.footer"))
                }

                Section {
                    Toggle(L("settings.consent"), isOn: $aiConsentGranted)
                    Link(destination: AIConsentView.privacyPolicy) {
                        Label(L("consent.policy"), systemImage: "hand.raised")
                    }
                } footer: {
                    Text(L("settings.consent.footer"))
                }

                Section {
                    Picker(L("settings.model"), selection: $model) {
                        ForEach(region.catalog.models) { option in
                            // Title + subtitle in the menu; the closed picker
                            // shows the name only.
                            VStack(alignment: .leading) {
                                Text(option.name)
                                Text(region.blurb(for: option))
                            }
                            .tag(option.id)
                        }
                    }
                    if let selected = region.catalog.models.first(where: { $0.id == model }) {
                        Text(region.blurb(for: selected))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    // The measured comparison only makes sense where the
                    // OpenAI models are on offer.
                    Text(L(region.catalog.models.contains { $0.provider == "openai" }
                        ? "settings.model.footer" : "settings.model.footer.regional"))
                }

                Section {
                    ForEach($party.members) { $member in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Button {
                                    avatarTargetID = member.id
                                    showAvatarPicker = true
                                } label: {
                                    AvatarView(party: party, memberID: member.id, size: 30)
                                }
                                .buttonStyle(.borderless)
                                TextField(L("settings.member.name"), text: $member.name)
                                if party.members.count > 1 {
                                    Button {
                                        party.remove(id: member.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.gray)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            // What this person doesn't eat — checked against
                            // every dish when the order is summarized.
                            HStack(spacing: 6) {
                                Text(L("settings.member.avoid"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(DietTag.avoidable) { tag in
                                    let on = member.avoidedTags.contains(tag)
                                    Button {
                                        party.toggle(tag, for: member.id)
                                    } label: {
                                        Text(tag.shortLabel)
                                            .font(.caption)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(
                                                Capsule().fill(on ? Color.red.opacity(0.15) : Color(.systemGray5))
                                            )
                                            .overlay(Capsule().stroke(on ? .red : .clear, lineWidth: 1))
                                            .foregroundStyle(on ? .red : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    HStack {
                        TextField(L("settings.member.addPlaceholder"), text: $newMemberName)
                            .onSubmit { addMember() }
                        Button(L("common.add"), action: addMember)
                            .disabled(newMemberName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text(L("settings.party.header"))
                } footer: {
                    Text(L("settings.party.footer"))
                }
                .photosPicker(isPresented: $showAvatarPicker, selection: $avatarPickerItem, matching: .images)
                .onChange(of: avatarPickerItem) {
                    guard let item = avatarPickerItem, let target = avatarTargetID else { return }
                    Task { @MainActor in
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            party.setAvatar(image, for: target)
                        }
                        avatarPickerItem = nil
                        avatarTargetID = nil
                    }
                }

                Section {
                    Toggle(L("settings.flatten"), isOn: $flattenLighting)
                } footer: {
                    Text(L("settings.flatten.footer"))
                }

                if region.catalog.images {
                    Section {
                        Toggle(L("settings.grid"), isOn: $thumbnailGridMode)
                    } footer: {
                        Text(L("settings.grid.footer"))
                    }
                } else {
                    Section {
                        Label(L("home.images.unavailable"), systemImage: "photo.artframe")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
                }
            }
            .task {
                await account.ensureSession()
                await account.refreshCredits()
            }
            .sheet(isPresented: $showShop) { ShopView() }
        }
    }

    // MARK: - Account

    /// No sign-in needed: a device account (「未登录（本机账号）」) or an
    /// Apple account. Both show the balance and can delete the account; Sign
    /// in with Apple is an optional extra on the device account, sign-out
    /// exists only for the Apple account (a device account has nothing to
    /// sign out of — it is this device).
    private var accountSection: some View {
        Section {
            Label {
                Text(L(account.isAppleAccount ? "settings.account.apple" : "settings.account.anonymous"))
            } icon: {
                Image(systemName: account.isAppleAccount ? "apple.logo" : "iphone")
            }
            CreditsCard(account: account, onBuy: { showShop = true })
                .padding(.vertical, 4)
            if !account.isAppleAccount {
                if !appleHintDismissed {
                    HStack(alignment: .top) {
                        Text(L("settings.account.appleHint"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            appleHintDismissed = true
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L("common.close"))
                    }
                }
                AppleSignInButton()
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } else {
                Button(L("settings.account.signOut")) { confirmSignOut = true }
                    .disabled(account.isBusy)
            }
            Button(L("settings.account.delete"), role: .destructive) { confirmDelete = true }
                .disabled(account.isBusy || !account.hasSession)
            if let notice = account.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
            if let message = account.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(L("settings.account.header"))
        } footer: {
            Text(L(account.isAppleAccount ? "settings.account.footer" : "settings.account.anonymous.footer"))
        }
        .confirmationDialog(
            L("settings.account.signOut.title"),
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button(L("settings.account.signOut"), role: .destructive) {
                Task { await account.signOut() }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("settings.account.signOut.message"))
        }
        .confirmationDialog(
            L("settings.account.delete.title"),
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button(L("settings.account.delete.confirm"), role: .destructive) {
                Task { await account.deleteAccount() }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("settings.account.delete.message"))
        }
    }
}
