import PhotosUI
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("openai_model") private var model = "gpt-4.1"
    @AppStorage("thumbnail_grid_mode") private var thumbnailGridMode = true
    @AppStorage("flatten_lighting") private var flattenLighting = true
    @AppStorage(AIConsentView.grantedKey) private var aiConsentGranted = false
    /// The language picker writes through `Localization`, so every screen in
    /// the app follows the choice immediately — see Localization.swift.
    @ObservedObject private var loc = Localization.shared
    @ObservedObject private var party = PartyStore.shared
    @ObservedObject private var account = AccountStore.shared
    @State private var confirmDelete = false
    @State private var newMemberName = ""
    @State private var avatarTargetID: UUID?
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var showAvatarPicker = false

    private let models = ["gpt-4.1", "gpt-5-mini", "gpt-5", "gpt-4o"]

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
                        ForEach(models, id: \.self) { Text($0) }
                    }
                } footer: {
                    Text(L("settings.model.footer"))
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

                Section {
                    Toggle(L("settings.grid"), isOn: $thumbnailGridMode)
                } footer: {
                    Text(L("settings.grid.footer"))
                }
            }
            .navigationTitle(L("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
                }
            }
            .task { await account.refreshCredits() }
        }
    }

    // MARK: - Account

    /// Signed out: the Apple button and what an account gives you. Signed
    /// in: the balance, what things cost, sign out and delete.
    private var accountSection: some View {
        Section {
            if account.isSignedIn {
                CreditsCard(account: account)
                    .padding(.vertical, 4)
                Button(L("settings.account.signOut")) { account.signOut() }
                Button(L("settings.account.delete"), role: .destructive) { confirmDelete = true }
                    .disabled(account.isBusy)
            } else {
                AppleSignInButton()
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            if let message = account.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(L("settings.account.header"))
        } footer: {
            Text(L(account.isSignedIn ? "settings.account.footer" : "settings.account.signedOut.footer"))
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
